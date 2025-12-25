import pandas as pd
import glob

li = []

print("loading data...")

for filename in glob.iglob("import/*.csv"):
    df = pd.read_csv(filename, index_col=None, header=0, low_memory=False)
    li.append(df)

df = pd.concat(li, axis=0, ignore_index=True)

# Convert _time to datetime
df["_time"] = pd.to_datetime(df["_time"], format="ISO8601")

# df = df[(df['_time'] >= '2025-05-25 11:00:00') & (df['_time'] <= '2025-05-25 11:00:40')]

print("splitting data...")

electrical_cols = [
    "_time",
    "hz",
    "i1",
    "i2",
    "i3",
    "kWh",
    "kw",
    "kw1",
    "kw2",
    "kw3",
    "v1",
    "v12",
    "v2",
    "v23",
    "v3",
    "v31",
]
physical_cols = [
    "_time",
    "feedpump",
    "lockout",
    "pressure",
    "running",
    "steam",
    "temp1",
    "temp2",
    "temp3",
    "water",
]

df_electrical = (
    df[electrical_cols]
    .dropna(subset=["_time"])
    .dropna(how="all", subset=electrical_cols[1:])
    .sort_values("_time")
)
df_physical = (
    df[physical_cols]
    .dropna(subset=["_time"])
    .dropna(how="all", subset=physical_cols[1:])
    .sort_values("_time")
)

df_physical[["feedpump", "lockout", "running"]] = df_physical[
    ["feedpump", "lockout", "running"]
].astype(bool)

print("merging data...")

df_electrical = df_electrical.set_index("_time")
df_physical = df_physical.set_index("_time")
df_physical = df_physical.reindex(
    df_electrical.index, method="backfill", limit=1, tolerance=pd.Timedelta("1.5s")
)
merged = pd.merge(
    df_electrical, df_physical, left_index=True, right_index=True, how="left"
)
merged = merged.reset_index()

'''
print(merged.info(), df_physical.info(), df_electrical.info())
merged = merged[
    (merged["_time"] >= "2025-05-25 11:00:00")
    & (merged["_time"] <= "2025-05-25 11:00:40")
]
print(merged[["_time", "kw", "pressure", "feedpump"]])
# exit()
'''

print("saving data...")

merged.to_csv("merged_data.csv.gz", index=False, compression="gzip")

print(merged.info(show_counts=True))
