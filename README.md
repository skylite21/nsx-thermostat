# Tasmota thermostat

This is simple thermostat specifically for the SonOFF NSPanel **not the pro version**. It is based on the Tasmota firmware and uses the built-in temperature sensor and relay to control the temperature in a room.

## Features

- Set the desired temperature
- control the relay to turn on/off the heater (L1)
- Display local outside temperature fetched from open-meteo.com

![UI](images/demo.png)

## Installation

You need to install tasmota on the device first.

Video tutorial: [https://www.youtube.com/watch?v=sCrdiCzxMOQ](https://www.youtube.com/watch?v=sCrdiCzxMOQ)

2. Upload the autoexec.be file found in this repository. You can start a webserver with the following command if you have python3 installed:

```bash
python3 -m http.server
```

Then just note the IP address and port number and use it in the following command into the tasomta console:
Note that you need to check the variables in autoexec.be and adjust them to your needs, for example the location of the outside temperature. You can re-upload the file after changing it.

```bash
Backlog UrlFetch http://192.168.1.6:8000/autoexec.be; Restart 1
```

After reboot, use the following to flash the display in the console:
    
```bash

FlashNextion http://192.168.1.6:8000/nsx.tft
```

# Configuration

The temperature sensor in the SonOFF NSPanel is not very accurate. If you enter this command in the console, you improve it bit. Not going to be berfect but better.

```bash

ADCParam1 2,12400,8800,3950
```
or this is a new one which is even better:

```bash
AdcParam1 2,12000,9900,3950
```



To ignore default button behaviour of controlling power outputs enter this command in the console:

```
SetOption73 1

``` 


# Rules to control the buttons (optional)
```
Rule1
ON Event#SendButtons DO Backlog Publish2 stat/%topic%/BUTTON {"Button1":{"Action":"SINGLE"}}; Publish2 stat/%topic%/BUTTON {"Button2":{"Action":"SINGLE"}} ENDON
```

Tasmota flashing commands (from the youtube video)

```
esptool.py flash_id
esptool.py read_flash 0x0 0x400000 nspanel.bin
```


Template (from https://templates.blakadder.com/sonoff_NSPanel.html)
```
{"NAME":"NSPanel","GPIO":[0,0,0,0,3872,0,0,0,0,0,32,0,0,0,0,225,0,480,224,1,0,0,0,33,0,0,0,0,0,0,0,0,0,0,4736,0],"FLAG":0,"BASE":1,"CMND":"ADCParam1 2,11200,10000,3950 | Sleep 0 | BuzzerPWM 1"}
```
