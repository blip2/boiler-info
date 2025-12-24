# pip install pandas influxdb_client

from influxdb_client import InfluxDBClient
import pandas as pd
from datetime import datetime, timedelta

bucket = "data"
org = "pi"
client = InfluxDBClient(
    url="http://localhost:8086",
    token="9PoWBQdMoza6Rb",
    org="pi",
    timeout=30000,
)

query_api = client.query_api()

diff = 1
start = datetime(year=2025, month=12, day=1)
end = datetime(year=2025, month=12, day=24)


position = start
while position < end:
    df = pd.DataFrame()
    
    stop = position + timedelta(days=diff)
    
    print(f"getting data from {position} to {stop}")

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

    df.to_csv(f"lmws_data_{position}.csv")
    print(f"exported data to lmws_data_{position}.csv")
# df.to_hdf("lmws_data.h5", key="boiler", append=True)

