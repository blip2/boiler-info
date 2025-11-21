import os
import time
import minimalmodbus
import influxdb_client

IO_ADDRESS = 1


def expandRegister(value):
    return [x == "1" for x in "{0:08b}".format(value)[::-1]]


def buildRegister(value):
    return int("".join([str(int(x)) for x in value]), 2)


io_device = minimalmodbus.Instrument("/dev/ttyUSB0", IO_ADDRESS)

reg = [False, False, False, True, False, False, False, True]
reg_bin = buildRegister(reg)

print(reg, reg_bin)

io_device.write_register(166, reg_bin)

ui_res = io_device.read_register(166)
ui_res_ex = expandRegister(ui_res)

print(ui_res, ui_res_ex)

#pulse5 = io_device.read_long(30, functioncode=4)
#if not dis[2] and pulse5:
#    io_device.write_long(30, 0)
#    pulse5 = io_device.read_long(30, functioncode=4)

