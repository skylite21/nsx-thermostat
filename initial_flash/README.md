

ESP-Flasher macos

https://github.com/Jason2866/ESP_Flasher


Flash the tasmota32-nspanel.factory.bin file to the device using the ESP-Flasher tool.

Tasmota flashing commands (from the youtube video)

```
esptool.py flash_id
esptool.py read_flash 0x0 0x400000 nspanel.bin
```

Template (from https://templates.blakadder.com/sonoff_NSPanel.html)
```
{"NAME":"NSPanel","GPIO":[0,0,0,0,3872,0,0,0,0,0,32,0,0,0,0,225,0,480,224,1,0,0,0,33,0,0,0,0,0,0,0,0,0,0,4736,0],"FLAG":0,"BASE":1,"CMND":"ADCParam1 2,11200,10000,3950 | Sleep 0 | BuzzerPWM 1"}
```


temp reader fix:

ADCParam1 2,12400,8800,3950

Disable buttons:
SetOption73 1


Backlog UrlFetch http://192.168.99.160:8000/autoexec.be; Restart 1

FlashNextion http://192.168.99.160:8000/nsx.tft
