# Boiler Modbus Logging

A script and Influx/Grafana stack for logging and displaying data from a iSMA-B-MIX18 I/O module and iEM3150 energy meter.

Written for the LMWS's 'new' boiler.

# Initialisation

For influxdb3:
`docker compose exec influxdb influxdb3 create token --admin`
`docker compose exec influxdb influxdb3 create database --token PASTE data`

# Authors

Ben Hussey <ben@blip2.net>
