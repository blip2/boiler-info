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


def expandRegister(value):
    return [x == "1" for x in "{0:05b}".format(value)[::-1]]


def buildRegister(value):
    return int("".join([str(int(x)) for x in value]), 2)


instrument = minimalmodbus.Instrument(
    os.environ["SERIAL_DEVICE"], int(os.environ["SERIAL_ADDRESS"])
)


def get_data():
    di = instrument.read_register(15)
    dis = expandRegister(di)

    pulse5 = instrument.read_long(30, functioncode=4)
    if not dis[2] and pulse5:
        instrument.write_long(30, 0)
        pulse5 = instrument.read_long(30, functioncode=4)

    ui1 = instrument.read_register(70)  # mV
    pressure = ui1 / 1

    data = {
        "running": dis[0],
        "lockout": dis[1],
        "feedpump": dis[2],
        "water": pulse5,
        "pressure": pressure,
    }

    # print(data)

    p = (
        influxdb_client.Point("boiler")
        .field("running", dis[0])
        .field("lockout", dis[1])
        .field("feedpump", dis[2])
        .field("water", pulse5)
        .field("pressure", pressure)
    )
    write_api.write(bucket=bucket, org=org, record=p)


while True:
    get_data()
    time.sleep(15)
