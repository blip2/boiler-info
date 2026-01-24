#!/bin/bash
set -e

# ============================================================================
# InfluxDB 2 to InfluxDB 3 Migration Script
# ============================================================================
# Two-stage migration:
#   Stage 1: ./migrate-influx2-to-3.sh export  - Export from InfluxDB 2
#   Stage 2: ./migrate-influx2-to-3.sh import  - Import into InfluxDB 3
#
# Prerequisites:
#   - influx CLI (v2) installed for export
#   - influxdb3 CLI or docker for import
# ============================================================================

# --- Configuration ---
# InfluxDB 2 settings (source)
INFLUX2_HOST="${INFLUX2_HOST:-http://localhost:8086}"
INFLUX2_ORG="${INFLUX2_ORG:-}"
INFLUX2_BUCKET="${INFLUX2_BUCKET:-data}"
INFLUX2_TOKEN="${INFLUX2_TOKEN:-}"

# InfluxDB 3 settings (destination)
INFLUX3_HOST="${INFLUX3_HOST:-http://localhost:8181}"
INFLUX3_DATABASE="${INFLUX3_DATABASE:-data}"
INFLUX3_TOKEN="${INFLUX3_TOKEN:-}"

# Export settings
EXPORT_DIR="${EXPORT_DIR:-./influx_export}"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# --- Show usage ---
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  export    Export data from InfluxDB 2 to line protocol files"
    echo "  import    Import line protocol files into InfluxDB 3"
    echo ""
    echo "Environment variables for export:"
    echo "  INFLUX2_HOST    InfluxDB 2 URL (default: http://localhost:8086)"
    echo "  INFLUX2_ORG     InfluxDB 2 organization (required)"
    echo "  INFLUX2_BUCKET  Bucket to export (default: data)"
    echo "  INFLUX2_TOKEN   InfluxDB 2 API token (required)"
    echo "  EXPORT_DIR      Directory for exported files (default: ./influx_export)"
    echo ""
    echo "Environment variables for import:"
    echo "  INFLUX3_HOST      InfluxDB 3 URL (default: http://localhost:8181)"
    echo "  INFLUX3_DATABASE  Database to import into (default: data)"
    echo "  INFLUX3_TOKEN     InfluxDB 3 token (optional for Core edition)"
    echo "  EXPORT_DIR        Directory containing exported files (default: ./influx_export)"
    echo "  IMPORT_METHOD     Import method: auto, docker, http (default: auto)"
    echo ""
    echo "Example:"
    echo "  # Stage 1: Export from InfluxDB 2"
    echo "  export INFLUX2_ORG=myorg INFLUX2_TOKEN=mytoken"
    echo "  $0 export"
    echo ""
    echo "  # Stage 2: Import to InfluxDB 3"
    echo "  $0 import"
    exit 1
}

# ============================================================================
# STAGE 1: EXPORT FROM INFLUXDB 2
# ============================================================================

validate_export_config() {
    local missing=0

    if [[ -z "$INFLUX2_TOKEN" ]]; then
        log_error "INFLUX2_TOKEN is required"
        missing=1
    fi

    if [[ -z "$INFLUX2_ORG" ]]; then
        log_error "INFLUX2_ORG is required"
        missing=1
    fi

    if ! command -v influx &> /dev/null; then
        log_error "influx CLI (v2) is required for export"
        log_info "Install from: https://docs.influxdata.com/influxdb/v2/tools/influx-cli/"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

get_measurements() {
    # Note: log to stderr so it doesn't mix with the output
    echo "[INFO] Fetching measurements from InfluxDB 2..." >&2

    influx query \
        --host "$INFLUX2_HOST" \
        --org "$INFLUX2_ORG" \
        --token "$INFLUX2_TOKEN" \
        --raw \
        "import \"influxdata/influxdb/schema\"
         schema.measurements(bucket: \"$INFLUX2_BUCKET\")" 2>/dev/null \
    | grep -v "^#" | grep -v "^," | grep -v "^$" | tail -n +2 | cut -d',' -f4 | grep -v "^_" | grep -v "string" | sort -u
}

export_measurement() {
    local measurement=$1
    local output_file="$EXPORT_DIR/${measurement}.lp"

    log_step "Exporting measurement: $measurement"

    # Export using Flux query to CSV
    influx query \
        --host "$INFLUX2_HOST" \
        --org "$INFLUX2_ORG" \
        --token "$INFLUX2_TOKEN" \
        --raw \
        "from(bucket: \"$INFLUX2_BUCKET\")
         |> range(start: 1970-01-01T00:00:00Z)
         |> filter(fn: (r) => r._measurement == \"$measurement\")
         |> drop(columns: [\"_start\", \"_stop\"])" \
    > "$output_file.csv" 2>/dev/null || true

    if [[ ! -s "$output_file.csv" ]]; then
        log_warn "No data exported for measurement: $measurement"
        rm -f "$output_file.csv"
        return
    fi

    # Debug: show CSV file info
    local csv_lines=$(wc -l < "$output_file.csv")
    log_info "CSV has $csv_lines lines"
    log_info "First 10 lines of CSV:"
    head -10 "$output_file.csv" | while read line; do echo "    $line"; done

    # Convert CSV to Line Protocol
    log_info "Converting to line protocol..."
    python3 - "$output_file.csv" "$output_file" "$measurement" << 'PYTHON_SCRIPT'
import sys
import csv
from datetime import datetime

csv_file = sys.argv[1]
lp_file = sys.argv[2]
default_measurement = sys.argv[3]

def escape_tag(s):
    return str(s).replace('\\', '\\\\').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

def escape_field_key(s):
    return str(s).replace('\\', '\\\\').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

def format_field_value(value):
    if value == '' or value is None:
        return None
    if value.lower() in ('true', 'false'):
        return value.lower()
    try:
        if '.' not in value and 'e' not in value.lower():
            return str(int(value)) + 'i'
        return str(float(value))
    except ValueError:
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def parse_time(time_str):
    time_str = time_str.rstrip('Z')
    if '.' in time_str:
        # Handle microseconds/nanoseconds - truncate to 6 digits
        parts = time_str.split('.')
        if len(parts[1]) > 6:
            time_str = parts[0] + '.' + parts[1][:6]
        dt = datetime.fromisoformat(time_str)
    else:
        dt = datetime.fromisoformat(time_str)
    return int(dt.timestamp() * 1_000_000_000)

with open(csv_file, 'r') as infile:
    # Skip annotation lines (start with #) to find the actual header
    lines = infile.readlines()

# Filter out annotation lines and empty lines
data_lines = []
header_found = False
for line in lines:
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith('#'):
        continue
    # First non-annotation, non-empty line is the header
    data_lines.append(line)

if len(data_lines) < 2:
    print(f"  No data rows found in CSV", file=sys.stderr)
    print(f"  Total: 0 points exported", file=sys.stderr)
    sys.exit(0)

# Debug: show first few lines
print(f"  CSV header: {data_lines[0].strip()[:100]}...", file=sys.stderr)
print(f"  First data: {data_lines[1].strip()[:100]}...", file=sys.stderr)

import io
csv_content = ''.join(data_lines)
reader = csv.DictReader(io.StringIO(csv_content))

count = 0
with open(lp_file, 'w') as outfile:
    for row in reader:
        measurement = row.get('_measurement', default_measurement)
        if not measurement:
            continue

        time_val = row.get('_time', row.get('time', ''))
        if not time_val:
            continue

        try:
            timestamp = parse_time(time_val)
        except Exception as e:
            print(f"  Time parse error: {e} for {time_val}", file=sys.stderr)
            continue

        # Collect tags (non-underscore, non-numeric string values)
        tags = []
        tag_keys = set()
        for key, value in row.items():
            if not key or key.startswith('_') or key in ('result', 'table', 'time'):
                continue
            if not value:
                continue
            try:
                float(value)
                continue  # numeric = field, not tag
            except:
                if value.lower() in ('true', 'false'):
                    continue  # boolean = field, not tag
                tags.append(f"{escape_tag(key)}={escape_tag(value)}")
                tag_keys.add(key)

        # Collect fields
        fields = []
        if '_field' in row and '_value' in row and row['_field'] and row['_value']:
            field_name = row['_field']
            field_value = format_field_value(row['_value'])
            if field_value:
                fields.append(f"{escape_field_key(field_name)}={field_value}")
        else:
            for key, value in row.items():
                if not key or key.startswith('_') or key in ('result', 'table', 'time'):
                    continue
                if key in tag_keys:
                    continue
                if not value:
                    continue
                field_value = format_field_value(value)
                if field_value:
                    fields.append(f"{escape_field_key(key)}={field_value}")

        if not fields:
            continue

        tag_str = ',' + ','.join(tags) if tags else ''
        field_str = ','.join(fields)
        line = f"{escape_tag(measurement)}{tag_str} {field_str} {timestamp}\n"
        outfile.write(line)
        count += 1

        if count % 10000 == 0:
            print(f"  Processed {count} points...", file=sys.stderr)

print(f"  Total: {count} points exported", file=sys.stderr)
PYTHON_SCRIPT

    rm -f "$output_file.csv"

    if [[ -s "$output_file" ]]; then
        local lines=$(wc -l < "$output_file")
        log_info "Exported $lines points to $output_file"
    else
        rm -f "$output_file"
    fi
}

do_export() {
    echo "=============================================="
    echo "  Stage 1: Export from InfluxDB 2"
    echo "=============================================="
    echo ""

    validate_export_config

    log_info "Source: $INFLUX2_HOST"
    log_info "Organization: $INFLUX2_ORG"
    log_info "Bucket: $INFLUX2_BUCKET"
    log_info "Export directory: $EXPORT_DIR"
    echo ""

    mkdir -p "$EXPORT_DIR"

    # Get measurements
    local measurements
    measurements=$(get_measurements 2>/dev/null) || true

    if [[ -n "$measurements" ]]; then
        log_info "Found measurements: $measurements"
        echo ""
        for measurement in $measurements; do
            export_measurement "$measurement"
        done
    else
        log_warn "Could not enumerate measurements, trying 'boiler'..."
        export_measurement "boiler"
    fi

    echo ""
    log_info "Export complete!"
    echo ""
    echo "Exported files:"
    ls -lh "$EXPORT_DIR"/*.lp 2>/dev/null || echo "  (no files exported)"
    echo ""
    echo "Next step: Run '$0 import' to import into InfluxDB 3"
}

# ============================================================================
# STAGE 2: IMPORT INTO INFLUXDB 3
# ============================================================================

validate_import_config() {
    if [[ ! -d "$EXPORT_DIR" ]]; then
        log_error "Export directory not found: $EXPORT_DIR"
        log_info "Run '$0 export' first"
        exit 1
    fi

    local lp_files=$(ls "$EXPORT_DIR"/*.lp 2>/dev/null | wc -l)
    if [[ $lp_files -eq 0 ]]; then
        log_error "No .lp files found in $EXPORT_DIR"
        log_info "Run '$0 export' first"
        exit 1
    fi
}

import_via_docker() {
    log_info "Importing via docker exec..."

    for lp_file in "$EXPORT_DIR"/*.lp; do
        if [[ ! -f "$lp_file" ]]; then
            continue
        fi

        local filename=$(basename "$lp_file")
        local lines=$(wc -l < "$lp_file")
        log_step "Importing $filename ($lines points)..."

        # Copy file to container
        docker cp "$lp_file" influxdb:/tmp/import.lp

        # Build command
        local cmd="influxdb3 write --database $INFLUX3_DATABASE --file /tmp/import.lp"
        if [[ -n "$INFLUX3_TOKEN" ]]; then
            cmd="$cmd --token $INFLUX3_TOKEN"
        fi

        # Import
        docker exec influxdb $cmd

        # Clean up
        docker exec influxdb rm /tmp/import.lp

        log_info "Imported $filename successfully"
    done
}

import_via_http() {
    log_info "Importing via HTTP API..."

    for lp_file in "$EXPORT_DIR"/*.lp; do
        if [[ ! -f "$lp_file" ]]; then
            continue
        fi

        local filename=$(basename "$lp_file")
        local lines=$(wc -l < "$lp_file")
        log_step "Importing $filename ($lines points)..."

        local auth_header=""
        if [[ -n "$INFLUX3_TOKEN" ]]; then
            auth_header="Authorization: Bearer $INFLUX3_TOKEN"
        fi

        # Split into chunks if large
        local chunk_size=5000
        if [[ $lines -gt $chunk_size ]]; then
            log_info "Splitting into chunks of $chunk_size..."
            split -l $chunk_size "$lp_file" "$lp_file.chunk."

            local chunk_num=0
            for chunk in "$lp_file.chunk."*; do
                chunk_num=$((chunk_num + 1))
                if [[ -n "$auth_header" ]]; then
                    curl -sf -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                        -H "Content-Type: text/plain" \
                        -H "$auth_header" \
                        --data-binary @"$chunk"
                else
                    curl -sf -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                        -H "Content-Type: text/plain" \
                        --data-binary @"$chunk"
                fi
                rm "$chunk"
                echo -ne "\r  Imported chunk $chunk_num..."
            done
            echo ""
        else
            if [[ -n "$auth_header" ]]; then
                curl -sf -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                    -H "Content-Type: text/plain" \
                    -H "$auth_header" \
                    --data-binary @"$lp_file"
            else
                curl -sf -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                    -H "Content-Type: text/plain" \
                    --data-binary @"$lp_file"
            fi
        fi

        log_info "Imported $filename successfully"
    done
}

do_import() {
    echo "=============================================="
    echo "  Stage 2: Import into InfluxDB 3"
    echo "=============================================="
    echo ""

    validate_import_config

    log_info "Destination: $INFLUX3_HOST"
    log_info "Database: $INFLUX3_DATABASE"
    log_info "Import directory: $EXPORT_DIR"
    echo ""

    echo "Files to import:"
    ls -lh "$EXPORT_DIR"/*.lp
    echo ""

    # Determine import method
    local method="${IMPORT_METHOD:-auto}"

    if [[ "$method" == "auto" ]]; then
        if docker ps --format '{{.Names}}' | grep -q '^influxdb$'; then
            method="docker"
        else
            method="http"
        fi
    fi

    log_info "Using import method: $method"
    echo ""

    case "$method" in
        docker)
            import_via_docker
            ;;
        http)
            import_via_http
            ;;
        *)
            log_error "Unknown import method: $method"
            exit 1
            ;;
    esac

    echo ""
    log_info "Import complete!"
    echo ""
    echo "You can verify the data with:"
    echo "  docker exec influxdb influxdb3 query --database $INFLUX3_DATABASE \"SELECT COUNT(*) FROM boiler\""
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    export)
        do_export
        ;;
    import)
        do_import
        ;;
    *)
        usage
        ;;
esac
