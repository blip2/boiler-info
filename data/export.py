# pip install pandas influxdb_client

from influxdb_client import InfluxDBClient
import pandas as pd
from datetime import datetime, timedelta

bucket = "data"
org = "pi"
client = InfluxDBClient(
    url="http://192.168.1.184:8086",
    token="9PoWBQdMoza6Rb",
    org="pi",
    timeout=30000,
)

query_api = client.query_api()

diff = 1

df = pd.DataFrame()

start = datetime(year=2025, month=11, day=28)
position = start
while position < start+timedelta(days=diff):
    stop = position + timedelta(days=diff)
    
    print(f"getting data from {start} to {stop}")

    query= f"""
    from(bucket: "data")
    |> range(start:{int(position.timestamp())}, stop: {int(stop.timestamp())})
    |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")"""

    output = query_api.query_data_frame(org="pi", query=query)

    if "feedpump" in output:
        output[["feedpump", "running", "lockout"]] = output[["feedpump", "running", "lockout"]].astype(str)

    df = pd.concat([df, output])

    position = position + timedelta(days=diff)

# print(df)

df.to_csv("lmws_data_2025-11-28.csv")
# df.to_hdf("lmws_data.h5", key="boiler", append=True)

