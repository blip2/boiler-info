#!/bin/bash
set -e

# ============================================================================
# InfluxDB 2 to InfluxDB 3 Migration Script
# ============================================================================
# This script exports all data from an InfluxDB 2 instance and imports it
# into an InfluxDB 3 instance.
#
# Prerequisites:
#   - influx CLI (v2) installed for export
#   - influxdb3 CLI installed for import (or use docker exec)
#   - Access to both InfluxDB 2 and InfluxDB 3 instances
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
BATCH_SIZE="${BATCH_SIZE:-10000}"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Validate configuration ---
validate_config() {
    local missing=0

    if [[ -z "$INFLUX2_TOKEN" ]]; then
        log_error "INFLUX2_TOKEN is required"
        missing=1
    fi

    if [[ -z "$INFLUX2_ORG" ]]; then
        log_error "INFLUX2_ORG is required"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Usage: Set environment variables before running:"
        echo "  export INFLUX2_HOST=http://localhost:8086"
        echo "  export INFLUX2_ORG=your-org"
        echo "  export INFLUX2_BUCKET=data"
        echo "  export INFLUX2_TOKEN=your-influx2-token"
        echo "  export INFLUX3_HOST=http://localhost:8181"
        echo "  export INFLUX3_DATABASE=data"
        echo "  export INFLUX3_TOKEN=your-influx3-token  # optional for InfluxDB 3 Core"
        echo ""
        exit 1
    fi
}

# --- Get list of measurements from InfluxDB 2 ---
get_measurements() {
    log_info "Fetching measurements from InfluxDB 2..."

    influx query \
        --host "$INFLUX2_HOST" \
        --org "$INFLUX2_ORG" \
        --token "$INFLUX2_TOKEN" \
        --raw \
        "import \"influxdata/influxdb/schema\"
         schema.measurements(bucket: \"$INFLUX2_BUCKET\")" \
    | tail -n +2 | grep -v "^$" | grep -v "^_" | cut -d',' -f4 | sort -u
}

# --- Export data from InfluxDB 2 to Line Protocol ---
export_measurement() {
    local measurement=$1
    local output_file="$EXPORT_DIR/${measurement}.lp"

    log_info "Exporting measurement: $measurement"

    # Export using Flux query to line protocol format
    influx query \
        --host "$INFLUX2_HOST" \
        --org "$INFLUX2_ORG" \
        --token "$INFLUX2_TOKEN" \
        --raw \
        "from(bucket: \"$INFLUX2_BUCKET\")
         |> range(start: 1970-01-01T00:00:00Z)
         |> drop(columns: [\"_start\", \"_stop\"])" \
    > "$output_file.csv" 2>/dev/null || true

    # Check if we got data
    if [[ ! -s "$output_file.csv" ]]; then
        log_warn "No data exported for measurement: $measurement"
        rm -f "$output_file.csv"
        return
    fi

    # Convert CSV to Line Protocol
    log_info "Converting $measurement to line protocol..."
    python3 - "$output_file.csv" "$output_file" "$measurement" << 'PYTHON_SCRIPT'
import sys
import csv
from datetime import datetime

csv_file = sys.argv[1]
lp_file = sys.argv[2]
default_measurement = sys.argv[3]

def escape_tag(s):
    """Escape special characters in tag keys/values"""
    return str(s).replace('\\', '\\\\').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

def escape_field_key(s):
    """Escape special characters in field keys"""
    return str(s).replace('\\', '\\\\').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

def format_field_value(value):
    """Format field value for line protocol"""
    if value == '' or value is None:
        return None
    # Try to detect type
    if value.lower() in ('true', 'false'):
        return value.lower()
    try:
        # Check if it's an integer
        if '.' not in value and 'e' not in value.lower():
            return str(int(value)) + 'i'
        # Otherwise treat as float
        return str(float(value))
    except ValueError:
        # It's a string
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def parse_time(time_str):
    """Convert RFC3339 timestamp to nanoseconds"""
    # Handle various timestamp formats
    time_str = time_str.rstrip('Z')
    if '.' in time_str:
        dt = datetime.fromisoformat(time_str)
    else:
        dt = datetime.fromisoformat(time_str)
    # Convert to nanoseconds since epoch
    return int(dt.timestamp() * 1_000_000_000)

with open(csv_file, 'r') as infile, open(lp_file, 'w') as outfile:
    reader = csv.DictReader(infile)

    count = 0
    for row in reader:
        # Skip annotation rows
        if row.get('', '').startswith('#'):
            continue

        # Get measurement name
        measurement = row.get('_measurement', default_measurement)
        if not measurement or measurement.startswith('#'):
            continue

        # Get timestamp
        time_val = row.get('_time', row.get('time', ''))
        if not time_val:
            continue

        try:
            timestamp = parse_time(time_val)
        except:
            continue

        # Build tags
        tags = []
        for key, value in row.items():
            if key.startswith('_') or key in ('', 'result', 'table', 'time'):
                continue
            if key == '_field' or key == '_value':
                continue
            # Detect if it's a tag (non-numeric, non-boolean)
            try:
                float(value)
                continue  # It's numeric, skip as tag
            except:
                if value.lower() in ('true', 'false'):
                    continue  # It's boolean, skip as tag
                if value:
                    tags.append(f"{escape_tag(key)}={escape_tag(value)}")

        # Build fields
        fields = []

        # Handle pivoted data (field name in _field, value in _value)
        if '_field' in row and '_value' in row:
            field_name = row['_field']
            field_value = format_field_value(row['_value'])
            if field_value:
                fields.append(f"{escape_field_key(field_name)}={field_value}")
        else:
            # Handle unpivoted data (each column is a field)
            for key, value in row.items():
                if key.startswith('_') or key in ('', 'result', 'table', 'time'):
                    continue
                # Skip if it's already identified as a tag
                if any(key in t for t in tags):
                    continue
                field_value = format_field_value(value)
                if field_value:
                    fields.append(f"{escape_field_key(key)}={field_value}")

        if not fields:
            continue

        # Build line protocol
        tag_str = ',' + ','.join(tags) if tags else ''
        field_str = ','.join(fields)
        line = f"{escape_tag(measurement)}{tag_str} {field_str} {timestamp}\n"
        outfile.write(line)
        count += 1

        if count % 10000 == 0:
            print(f"  Processed {count} points...", file=sys.stderr)

    print(f"  Total: {count} points exported", file=sys.stderr)
PYTHON_SCRIPT

    # Clean up CSV
    rm -f "$output_file.csv"

    if [[ -s "$output_file" ]]; then
        local lines=$(wc -l < "$output_file")
        log_info "Exported $lines points to $output_file"
    else
        rm -f "$output_file"
    fi
}

# --- Export all data from InfluxDB 2 ---
export_all_data() {
    mkdir -p "$EXPORT_DIR"

    # Method 1: Try to get measurements list
    local measurements
    measurements=$(get_measurements 2>/dev/null) || true

    if [[ -n "$measurements" ]]; then
        for measurement in $measurements; do
            export_measurement "$measurement"
        done
    else
        # Method 2: Export everything as a single file
        log_info "Could not get measurements list, exporting all data..."
        export_measurement "boiler"
    fi
}

# --- Import data into InfluxDB 3 ---
import_to_influx3() {
    log_info "Importing data into InfluxDB 3..."

    # Check if influxdb3 CLI is available
    if command -v influxdb3 &> /dev/null; then
        import_via_cli
    else
        import_via_docker
    fi
}

import_via_cli() {
    for lp_file in "$EXPORT_DIR"/*.lp; do
        if [[ ! -f "$lp_file" ]]; then
            continue
        fi

        local filename=$(basename "$lp_file")
        log_info "Importing $filename..."

        local auth_args=""
        if [[ -n "$INFLUX3_TOKEN" ]]; then
            auth_args="--token $INFLUX3_TOKEN"
        fi

        influxdb3 write \
            --host "$INFLUX3_HOST" \
            --database "$INFLUX3_DATABASE" \
            $auth_args \
            --file "$lp_file"

        log_info "Imported $filename successfully"
    done
}

import_via_docker() {
    log_info "Using docker exec to import data..."

    # Copy files to container
    for lp_file in "$EXPORT_DIR"/*.lp; do
        if [[ ! -f "$lp_file" ]]; then
            continue
        fi

        local filename=$(basename "$lp_file")
        log_info "Importing $filename via docker..."

        # Copy file to container
        docker cp "$lp_file" influxdb:/tmp/import.lp

        # Import using influxdb3 CLI inside container
        local auth_args=""
        if [[ -n "$INFLUX3_TOKEN" ]]; then
            auth_args="--token $INFLUX3_TOKEN"
        fi

        docker exec influxdb influxdb3 write \
            --database "$INFLUX3_DATABASE" \
            $auth_args \
            --file /tmp/import.lp

        # Clean up
        docker exec influxdb rm /tmp/import.lp

        log_info "Imported $filename successfully"
    done
}

# --- Alternative: Direct HTTP API import ---
import_via_http() {
    log_info "Importing via HTTP API..."

    for lp_file in "$EXPORT_DIR"/*.lp; do
        if [[ ! -f "$lp_file" ]]; then
            continue
        fi

        local filename=$(basename "$lp_file")
        log_info "Importing $filename via HTTP..."

        local auth_header=""
        if [[ -n "$INFLUX3_TOKEN" ]]; then
            auth_header="-H \"Authorization: Bearer $INFLUX3_TOKEN\""
        fi

        # Split file into chunks if too large
        local total_lines=$(wc -l < "$lp_file")
        local chunk_size=5000

        if [[ $total_lines -gt $chunk_size ]]; then
            log_info "Large file detected ($total_lines lines), splitting into chunks..."
            split -l $chunk_size "$lp_file" "$lp_file.chunk."

            for chunk in "$lp_file.chunk."*; do
                curl -s -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                    -H "Content-Type: text/plain" \
                    ${auth_header:+-H "Authorization: Bearer $INFLUX3_TOKEN"} \
                    --data-binary @"$chunk"
                rm "$chunk"
                echo -n "."
            done
            echo ""
        else
            curl -s -X POST "$INFLUX3_HOST/api/v2/write?bucket=$INFLUX3_DATABASE" \
                -H "Content-Type: text/plain" \
                ${auth_header:+-H "Authorization: Bearer $INFLUX3_TOKEN"} \
                --data-binary @"$lp_file"
        fi

        log_info "Imported $filename successfully"
    done
}

# --- Main ---
main() {
    echo "=============================================="
    echo "  InfluxDB 2 to InfluxDB 3 Migration Script"
    echo "=============================================="
    echo ""

    validate_config

    log_info "Source: $INFLUX2_HOST (bucket: $INFLUX2_BUCKET)"
    log_info "Destination: $INFLUX3_HOST (database: $INFLUX3_DATABASE)"
    echo ""

    # Step 1: Export from InfluxDB 2
    log_info "Step 1: Exporting data from InfluxDB 2..."
    export_all_data

    # Step 2: Import into InfluxDB 3
    log_info "Step 2: Importing data into InfluxDB 3..."

    # Check which import method to use
    if [[ "${IMPORT_METHOD:-auto}" == "http" ]]; then
        import_via_http
    else
        import_to_influx3
    fi

    echo ""
    log_info "Migration complete!"
    log_info "Exported data is saved in: $EXPORT_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Verify data in InfluxDB 3 using Grafana or influxdb3 query"
    echo "  2. Update your Grafana datasource to use SQL queries"
    echo "  3. Once verified, you can remove the old InfluxDB 2 instance"
}

# Run main function
main "$@"
