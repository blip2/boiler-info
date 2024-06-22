import os
import time
import minimalmodbus
import influxdb_client

bucket = os.environ["DOCKER_INFLUXDB_INIT_BUCKET"]
org = os.environ["DOCKER_INFLUXDB_INIT_ORG"]
client = influxdb_client.InfluxDBClient(
    url=f"http://{os.environ['DOCKER_INFLUXDB_INIT_HOST']}:{os.environ['DOCKER_INFLUXDB_INIT_PORT']}",
    token=os.environ["DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"],
    org=org,
)
write_api = client.write_api(write_options=influxdb_client.client.write_api.SYNCHRONOUS)

IO_ADDRESS = 1
METER_ADDRESS = 2


def expandRegister(value):
    return [x == "1" for x in "{0:05b}".format(value)[::-1]]


def buildRegister(value):
    return int("".join([str(int(x)) for x in value]), 2)


io_device = minimalmodbus.Instrument(os.environ["SERIAL_DEVICE"], IO_ADDRESS)

meter_device = minimalmodbus.Instrument(os.environ["SERIAL_DEVICE"], METER_ADDRESS)


def get_io_data():
    di = io_device.read_register(15)
    dis = expandRegister(di)

    pulse5 = io_device.read_long(30, functioncode=4)
    if not dis[2] and pulse5:
        io_device.write_long(30, 0)
        pulse5 = io_device.read_long(30, functioncode=4)

    ui1 = io_device.read_register(70, number_of_decimals=3)  # mV
    pressure = (float(ui1)-0.7)/0.325  # convert from 4-20mA signal across ~190 Ohm
    ui2 = io_device.read_register(73, number_of_decimals=1)  # C
    temp1 = float(ui2)
    ui3 = io_device.read_register(75, number_of_decimals=1)  # C
    temp2 = float(ui3)
    ui4 = io_device.read_register(77, number_of_decimals=1)  # C
    temp3 = float(ui4)
    ui5 = io_device.read_register(78, number_of_decimals=1)  # mV
    damper = float(ui5)

    data = {
        "running": dis[0],
        "lockout": dis[1],
        "feedpump": dis[2],
        "water": pulse5,
        "pressure": pressure,
        "temp1": temp1,
        "temp2": temp2,
        "temp3": temp3,
        "damper": damper,
    }

    p = (
        influxdb_client.Point("boiler")
        .field("running", dis[0])
        .field("lockout", dis[1])
        .field("feedpump", dis[2])
        .field("water", pulse5)
        .field("pressure", pressure)
        .field("temp1", temp1)
        .field("temp2", temp2)
        .field("temp3", temp3)
        .field("damper", damper)
    )
    write_api.write(bucket=bucket, org=org, record=p)


def get_meter_data():
    meter_longs = {
        "i1": 2999,
        "i2": 3001,
        "i3": 3003,
        "v12": 3019,
        "v23": 3021,
        "v31": 3023,
        "v1": 3027,
        "v2": 3029,
        "v3": 3031,
        "kw1": 3053,
        "kw2": 3055,
        "kw3": 3057,
        "kw": 3059,
        "hz": 3109,
        "kWh": 45099,
    }

    meter_output = {}

    for key in meter_longs:
        meter_output[key] = meter_device.read_float(meter_longs[key])

    p = influxdb_client.Point.from_dict(
        {
            "measurement": "boiler",
            "fields": meter_output,
        },
        influxdb_client.WritePrecision.NS,
    )
    write_api.write(bucket=bucket, org=org, record=p)

count = 1
while True:
    try:
        if count >= 10:
            get_io_data()
            count = 0
        get_meter_data()
    except minimalmodbus.NoResponseError:
        pass
    time.sleep(1)
    count += 1
