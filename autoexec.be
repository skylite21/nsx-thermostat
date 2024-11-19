import persist
var devicename = tasmota.cmd("DeviceName")["DeviceName"]

tasmota.cmd("State") # Display current device state and publish to %prefix%/%topic%/RESULT topic 
tasmota.cmd("TelePeriod")

var saved_outdoor_temp = persist.has("saved_outdoor_temp") ? persist.saved_outdoor_temp : "00"
var current_indoor_temp = "00"

var no_touch_sleep_timer = 30
var touch_wake = 1
var desired_temp = persist.has("desired_temp") ? persist.desired_temp : "00"
print("Desired temperature: after reboot:  " + desired_temp)

persist.save()


# utility function of returning the minimum of two numbers
def min(a, b)
  if a < b
      return a
  else
      return b
  end
end


class Nextion : Driver

    # Header bytes used in the custom communication protocol (0x55BB)
    static header = bytes('55BB')  
    
    # Size of each data block when flashing (4096 bytes)
    static flash_block_size = 4096  

    # Variables used in the class
    var flash_mode  # Indicates if the device is in flash mode (1) or normal mode (0)
    var flash_start_time_ms  # Timestamp when flashing started in milliseconds
    var flash_size  # Total size of the firmware to be flashed
    var flash_written  # Number of bytes already written to the device
    var flash_buffer  # Buffer holding data to be flashed
    var flash_offset  # Offset position in the flash data
    var flash_protocol_version  # Version of the flashing protocol to use
    var flash_protocol_baud  # Baud rate for flashing
    var waiting_for_offset  # Flag to indicate if we're waiting for an offset from the device
    var tcp_connection  # TCP client used to download firmware
    var serial_port  # Serial port used for communication with the Nextion display
    var last_percentage  # Last reported percentage of flashing completed
    var firmware_url  # URL of the firmware to download and flash

    # Function to split a byte stream into messages at header bytes (0x55BB).
    # Each message starts with the header 0x55BB. This function extracts those
    # messages and returns them as a list of byte chunks.
    def split_55(data_bytes)
        var message_list = []
        var total_size = size(data_bytes)   
        var index = total_size - 2   # Start from the second-to-last byte
        # Iterate backward through the byte stream to find the header (0x55BB)
        while index > 0
            # Check for the header bytes
            if data_bytes[index] == 0x55 && data_bytes[index+1] == 0xBB           
                message_list.push(data_bytes[index..total_size-1])  # Extract the message starting from header
                data_bytes = data_bytes[(0..index-1)]  # Remove extracted message from data_bytes
            end
            index -= 1  # Move backwards through data_bytes
        end
        message_list.push(data_bytes)  # Add any remaining data as a message
        return message_list
    end

    # Function to compute a CRC-16 checksum using MOBUS algorithm for a given data byte sequence.
    # The CRC is calculated using the MODBUS algorithm, which ensures that data 
    # integrity can be verified during transmission.
    # Input:
    # - data: Byte sequence to calculate the CRC for
    # - polynomial: (Optional) The polynomial used for the CRC calculation (default: 0xA001)
    def crc16(data, polynomial)
        if !polynomial  
            polynomial = 0xA001  # Default polynomial for MODBUS
        end
        # Initialize CRC to 0xFFFF as per MODBUS specification
        var crc = 0xFFFF 
        # Iterate through each byte in the input data
        for i:0..size(data)-1
            crc = crc ^ data[i]  # XOR current byte with CRC
            for j:0..7  # Process each bit in the byte
                if crc & 1
                    crc = (crc >> 1) ^ polynomial  # If LSB (least significant bit) is 1, shift and XOR with polynomial
                else
                    crc = crc >> 1  # If LSB is 0, just shift without XOR
                end
            end
        end
        return crc  # Return the calculated CRC value
    end

    # Function to encode payload using custom protocol
    # Format: [Header][Payload Length][Payload][CRC]
    def encode(payload)
        var message_bytes = bytes()
        message_bytes += self.header  # Add header bytes
        message_bytes.add(size(payload), 2)  # Add payload size as 2 bytes (little endian)
        message_bytes += bytes().fromstring(payload)  # Add the actual payload
        var checksum = self.crc16(message_bytes)  # Calculate CRC checksum of the message
        message_bytes.add(checksum, 2)  # Add CRC checksum as 2 bytes
        return message_bytes  # Return the complete message
    end

    # Function to encode Nextion commands
    def encode_nextion_command(command)
        var command_bytes = bytes().fromstring(command)
        command_bytes += bytes('FFFFFF')  # Add termination bytes (0xFF 0xFF 0xFF)
        return command_bytes
    end

    # Function to send Nextion commands to the display
    def send_nextion_command(command)
        import string
        var command_bytes = self.encode_nextion_command(command)
        self.serial_port.write(command_bytes)
        log(string.format("NXP: Nextion command sent = %s", str(command_bytes)), 3)       
    end

    # Function to send payload using custom protocol
    def send(payload)
        var message_bytes = self.encode(payload)
        if self.flash_mode == 1
            log("NXP: Skipped command because device is still flashing", 3)
        else 
            self.serial_port.write(message_bytes)
            log("NXP: Payload sent = " + str(message_bytes), 3)
        end
    end

    # Function to write bytes directly to the Nextion display
    def write_to_nextion(data_bytes)
        self.serial_port.write(data_bytes)
    end

    # Function to initialize the screen
    def screen_init()
        log("NXP: Screen Initialized")
        self.send_nextion_command("recmod=1")  # Enable protocol reparse mode
    end

    # Function to write a block of data to the Nextion display during flashing
    def write_block()
        import string
        log("FLH: Starting write_block", 3)
        while self.flash_written < self.flash_size
            # Fill flash buffer with data from TCP until it's full or no more data
            while size(self.flash_buffer) < self.flash_block_size && self.flash_written + size(self.flash_buffer) < self.flash_size
                if self.tcp_connection.available() > 0
                    var bytes_to_read = min(4096, self.flash_size - self.flash_written - size(self.flash_buffer))
                    self.flash_buffer += self.tcp_connection.readbytes(bytes_to_read)
                else
                    if !self.tcp_connection.connected()
                        log("FLH: TCP connection closed by server", 3)
                        break
                    end
                    tasmota.delay(50)
                    log("FLH: Waiting for data...", 3)
                end
            end
            # Write data to Nextion display
            if size(self.flash_buffer) > 0
                var data_to_write
                if size(self.flash_buffer) >= self.flash_block_size
                    data_to_write = self.flash_buffer[0..(self.flash_block_size - 1)]
                    self.flash_buffer = self.flash_buffer[self.flash_block_size..]
                else
                    data_to_write = self.flash_buffer
                    self.flash_buffer = bytes()
                end
                self.serial_port.write(data_to_write)
                self.flash_written += size(data_to_write)
                log("FLH: Wrote " + str(size(data_to_write)) + " bytes, total written: " + str(self.flash_written), 3)
                # Wait for acknowledgment (0x05) from Nextion
                var ack_received = false
                var ack_retry = 0
                while !ack_received && ack_retry < 10
                    if self.serial_port.available() > 0
                        var ack = self.serial_port.read()
                        if size(ack) > 0 && ack[0] == 0x05
                            ack_received = true
                            break
                        end
                    else
                        tasmota.delay(50)
                        ack_retry += 1
                    end
                end
                if !ack_received
                    log("FLH: No acknowledgment received from Nextion", 2)
                    return -1  # Error occurred
                end
                # Update progress percentage
                var percentage = int((self.flash_written * 100) / self.flash_size)
                if self.last_percentage != percentage
                    self.last_percentage = percentage
                    tasmota.publish_result("{\"Flashing\":{\"complete\":" + str(percentage) + ",\"time_elapsed\":" + str((tasmota.millis() - self.flash_start_time_ms) / 1000) + "}}", "RESULT")
                end
            else
                if !self.tcp_connection.connected()
                    log("FLH: No more data and connection closed", 3)
                    break
                end
                tasmota.delay(50)
            end
        end
        # Check if flashing is complete
        if self.flash_written >= self.flash_size
            log("FLH: Flashing complete - Time elapsed: " + str((tasmota.millis() - self.flash_start_time_ms) / 1000) + " seconds", 3)
            self.flash_mode = 0
            # Reset serial port to default baud rate
            self.serial_port.deinit()
            self.serial_port = serial(17, 16, 115200, serial.SERIAL_8N1)
        else
            log("FLH: Flashing incomplete, total written: " + str(self.flash_written) + " bytes", 2)
        end
    end

    def handle_thermostat()
      if current_indoor_temp == "00" || desired_temp == "00"
        return
      end
      self.send_raw_nextion_command('targetTemp.val='+desired_temp)
      if int(current_indoor_temp) < int(desired_temp)
        tasmota.cmd("Power1 1")
        self.send_raw_nextion_command('vis heat,1')
      else
        tasmota.cmd("Power1 0")
        self.send_raw_nextion_command('vis heat,0')
      end
    end

    # Function called every 100 milliseconds to process incoming data
    def every_100ms()
        if self.serial_port.available() > 0
            var message = self.serial_port.read()
            print("NXP: Received Raw =", message)
            if size(message) > 0
                import string
                print(string.format("NXP: Received Raw = %s", str(message)), 3)
                if (self.flash_mode == 1)
                    # Handle messages during flashing
                    var message_str = message[0..-4].asstring()
                    if string.find(message_str, "comok 2")>=0
                        tasmota.delay(50)
                        log("FLH: Send (High Speed) flash start")
                        self.flash_start_time_ms = tasmota.millis()
                        if self.flash_protocol_version == 0
                            self.send_nextion_command(string.format("whmi-wri %d,%d,res0", self.flash_size, self.flash_protocol_baud))
                        else
                            self.send_nextion_command(string.format("whmi-wris %d,%d,res0", self.flash_size, self.flash_protocol_baud))
                        end
                        if self.flash_protocol_baud != 115200
                            tasmota.delay(50)
                            self.serial_port.deinit()
                            self.serial_port = serial(17, 16, self.flash_protocol_baud, serial.SERIAL_8N1)
                        end
                    elif size(message)==1 && message[0]==0x08
                        log("FLH: Waiting for offset...", 3)
                        self.waiting_for_offset = 1
                    elif size(message) == 4 && self.waiting_for_offset == 1
                        self.waiting_for_offset = 0
                        self.flash_offset = message.get(0, 4)
                        log("FLH: Flash offset marker " + str(self.flash_offset), 3)
                        if self.flash_offset != 0
                            print("Sending the url to open_url_at")
                            print(self.firmware_url)
                            self.open_url_at(self.firmware_url, self.flash_offset)
                            self.flash_written = self.flash_offset
                        end
                        self.write_block()
                    elif size(message)==1 && message[0]==0x05
                        self.write_block()
                    else
                        log("FLH: Something has gone wrong flashing display firmware [" + str(message) + "]", 2)
                    end
                else
                    # Handle messages in normal mode
                    var messages = self.split_55(message)
                    # these two lines are all I need I think
                    var string_message = message.asstring()
                    print("My Received message = " + string_message)
                    # if string starts with desired: then save the value after the colon
                    if string.find(string_message, "desired:")>=0
                        desired_temp = string.split(string_message, ":")[1]
                        persist.desired_temp = desired_temp
                        print("Desired temperature: " + desired_temp)
                        persist.save()
                        self.handle_thermostat()
                    end
                    # these are not really needed but I keep them for reference
                    for i:0..size(messages)-1
                        message = messages[i]
                        if size(message) > 0
                            if message == bytes('000000FFFFFF88FFFFFF')
                                self.screen_init()
                            elif size(message)>=2 && message[0]==0x55 && message[1]==0xBB
                                var json_message = string.format("{\"CustomRecv\":\"%s\"}", message[4..-3].asstring())
                                tasmota.publish_result(json_message, "RESULT")        
                            elif message[0] == 0x07 && size(message) == 1  # BELL/Buzzer command
                                tasmota.cmd("buzzer 1,1")
                            else
                                var json_message = string.format("{\"nextion\":\"%s\"}", str(message[0..-4]))
                                tasmota.publish_result(json_message, "RESULT")        
                                print("NXP: Received message = " + str(message[4..-3].asstring()))
                            end
                        end       
                    end
                end
            end
#        else
#          print("NXP: Waiting for data...")
        end
    end      

    # Function to begin the flashing process
    def begin_nextion_flash()
        # We need to reinitialize the serial port for flashing
        self.serial_port.deinit()
        self.serial_port = serial(17, 16, 115200, serial.SERIAL_8N1)
        self.flash_written = 0
        self.waiting_for_offset = 0
        self.flash_offset = 0
        print("Sending flash start command")
        self.send_nextion_command('DRAKJHSUYDGBNCJHGJKSHBDN')  # Magic string to initiate flash mode
        print("Disabling protocol reparse mode")
        self.send_nextion_command('recmod=0')
        self.send_nextion_command('recmod=0')
        self.flash_mode = 1
        print("Flash mode enabled")
        self.send_nextion_command("connect")        
        print("Connecting to Nextion display")
    end

    def parse_url(url)
      import string
      var protocol = ""
      var host = ""
      var port = 0
      var path = "/"

      # Extract the protocol
      var idx = string.find(url, "://")
      if idx >= 0
          protocol = url[0..(idx-1)]
          url = url[(idx+3)..]  # Remove the protocol part
      else
          protocol = "http"  # Default protocol
      end

      # Find the path (everything after the first '/')
      idx = string.find(url, "/")
      if idx >= 0
          path = url[idx..]  # Path starts from the first '/'
          url = url[0..(idx-1)]  # Remove the path part from URL
      else
          path = "/"  # Default path
      end

      # Check for a port in the host (indicated by ':')
      idx = string.find(url, ":")
      if idx >= 0
          host = url[0..(idx-1)]  # Host part is everything before ':'
          port = int(url[(idx+1)..])  # Extract the port and convert to integer
      else
          host = url  # The remaining URL is the host
          port = protocol == "https" ? 443 : 80  # Assign default port based on protocol
      end

      # Return the extracted components
      var result = { "protocol": protocol, "host": host, "port": port, "path": path }
      print(result)
      return result
    end

# Function to send a Nextion command and print response
  def send_raw_nextion_command(command)
      print("NXP: Sending command: " + command)
      var b = bytes().fromstring(command)
      b += bytes('FFFFFF')  # Add termination bytes
      self.serial_port.write(b)
  end

    
    # Function to open the firmware URL at a specific position (offset)
    def open_url_at(url, position)
        import string
        self.firmware_url = url
        var url_components = self.parse_url(url)  # Use the parse_url function
        var host = url_components["host"]
        var port = url_components["port"]
        var get_path = url_components["path"]
        print("FLH: Host: " + host + ", Port: " + string.format("%d", port) + ", Path: " + get_path)
        self.tcp_connection = tcpclient()
        self.tcp_connection.connect(host, port)
        print("connected to host")
        log("FLH: Connected: " + str(self.tcp_connection.connected()), 3)
        var get_request = "GET " + get_path + " HTTP/1.1\r\n"
        get_request += "Host: " + host + "\r\n"
        if position > 0
            get_request += string.format("Range: bytes=%d-\r\n", position)
        end
        get_request += "\r\n"
        self.tcp_connection.write(get_request)
        var available_bytes = self.tcp_connection.available()
        print("FLH: Available bytes: " + str(available_bytes))

        # Retry logic if no data is immediately available
        var retry_count = 1
        while available_bytes == 0 && retry_count < 10
            tasmota.delay(100 * retry_count)
            tasmota.yield()
            retry_count += 1
            log("FLH: Retry " + str(retry_count), 3)
            available_bytes = self.tcp_connection.available()
        end
        if available_bytes == 0
            log("FLH: Nothing available to read!", 3)
            return -1  # Error occurred
        end
        var response = self.tcp_connection.readbytes()
        print("Response arrived")
        var idx2 = 0
        var headers = nil
        # Parse HTTP headers
        while idx2 < size(response) && headers == nil
            if response[idx2..(idx2+3)] == bytes().fromstring("\r\n\r\n")
                headers = response[0..(idx2+3)].asstring()
                self.flash_buffer = response[(idx2+4)..]
            else
                idx2 += 1
            end
        end
        if headers == nil
            log("FLH: Failed to parse HTTP headers", 2)
            return -1
        end
        # Check for successful HTTP response
        if string.find(headers, "200 OK") >= 0 || string.find(headers, "206 Partial Content") >= 0
            log("FLH: HTTP Response is 200 OK or 206 Partial Content", 3)
        else
            log("FLH: HTTP Response is not 200 OK or 206 Partial Content", 3)
            print(headers)
            return -1
        end
        # Only set flash size if starting from the beginning
        if position == 0
            # Extract Content-Length from HTTP headers
            var tag = "Content-Length: "
            var content_length_idx = string.find(headers, tag)
            if content_length_idx >= 0
                var content_length_end = string.find(headers, "\r\n", content_length_idx)
                var content_length_str = headers[(content_length_idx + size(tag))..(content_length_end - 1)]
                self.flash_size = int(content_length_str)
                log("FLH: Flash file size: " + str(self.flash_size), 3)
            else
                log("FLH: Content-Length header not found.", 2)
                return -1
            end
        else
            # Handle servers that ignore the Range header
            if string.find(headers, "200 OK") >= 0
                log("FLH: Server did not honor Range request, restarting from beginning", 3)
                self.flash_offset = 0
                self.flash_written = 0
                return self.open_url_at(url, 0)
            end
        end
    end

    # Function to initiate the flashing process
    def flash_nextion(url)
        self.flash_size = 0
        print("Opening firmware URL: " + url)
        var result = self.open_url_at(url, 0)
        if result != -1
            print("Beginning flash process...")
            self.begin_nextion_flash()
        end
    end

    # Initialization function
    def init()
        log("NXP: Initializing Driver")
        self.serial_port = serial(17, 16, 115200, serial.SERIAL_8N1)
        self.flash_mode = 0
        self.flash_protocol_version = 1
        self.flash_protocol_baud = 9600
    end

end

var nextion = Nextion()

tasmota.add_driver(nextion)

def flash_nextion(cmd, idx, payload, payload_json)
    def task()        
        nextion.flash_protocol_version = 0
        nextion.flash_protocol_baud = 115200
        nextion.firmware_url = payload
        print('Flashing Nextion display with firmware from URL: ')
        print(payload)
        nextion.flash_nextion(payload)
    end
    tasmota.set_timer(0,task)
    tasmota.resp_cmnd_done()
end

tasmota.add_cmd('FlashNextion', flash_nextion)

# initialize serial port as a global variable
# serial_port = serial(17, 16, 115200, serial.SERIAL_8N1)

# Map of return code meanings
var return_code_meanings = {
    0x00: "Invalid instruction",
    0x01: "Instruction executed successfully",
    0x02: "Component ID invalid or does not exist",
    0x03: "Page ID invalid or does not exist",
    0x04: "Picture ID invalid or does not exist",
    0x05: "Font ID invalid or does not exist",
    0x1A: "Invalid variable name or attribute",
    0x1B: "Invalid variable operation",
    0x1C: "Failed to assign",
    0x66: "Current page number is",
    0x1E: "Invalid number of parameters",
    # Add other codes as needed
}

def get_weather()
  import json
  var weather_code_list = {
    "0": "Clear sky",
    "1": "Mainly clear",
    "2": "Partly cloudy",
    "3": "Overcast",
    "45": "Fog",
    "48": "Depositing rime fog",
    "51": "Drizzle: Light intensity",
    "53": "Drizzle: Moderate intensity",
    "55": "Drizzle: Dense intensity",
    "56": "Freezing Drizzle: Light intensity",
    "57": "Freezing Drizzle: Dense intensity",
    "61": "Rain: Slight intensity",
    "63": "Rain: Moderate intensity",
    "65": "Rain: Heavy intensity",
    "66": "Freezing Rain: Light intensity",
    "67": "Freezing Rain: Heavy intensity",
    "71": "Snow fall: Slight intensity",
    "73": "Snow fall: Moderate intensity",
    "75": "Snow fall: Heavy intensity",
    "77": "Snow grains",
    "80": "Rain showers: Slight intensity",
    "81": "Rain showers: Moderate intensity",
    "82": "Rain showers: Violent intensity",
    "85": "Snow showers: Slight intensity",
    "86": "Snow showers: Heavy intensity",
    "95": "Thunderstorm: Slight or moderate",
    "96": "Thunderstorm with slight hail",
    "99": "Thunderstorm with heavy hail"
  };

  var cl = webclient()
  #var url = "http://wttr.in/" + loc + '?format=j2'
  # go to https://open-meteo.com/ if you need an api key
  var url = 'http://api.open-meteo.com/v1/forecast?latitude=47.48&longitude=19.2539&current=temperature_2m,weather_code&forecast_days=1'
  cl.set_useragent("curl/7.72.0")
  cl.set_follow_redirects(true)
  cl.begin(url)
  if cl.GET() == "200" || cl.GET() == 200
    var b = json.load(cl.get_string())
    var temp = b['current']['temperature_2m']
    print(b)
    var weather = weather_code_list[str(b['current']['weather_code'])]
    log('NSP: Weather update: ' + str(temp) + '°C, ' + weather, 3)
    persist.saved_outdoor_temp = temp
    return temp
  else
    log('NSP: Weather update failed!', 3)
    return saved_outdoor_temp
  end
end

import json
import math

def set_indoor_temp()
  var sensors=json.load(tasmota.read_sensors())
  log('NSP: Indoor temperature: ' + str(sensors), 3)
  var temperature = str(math.round(sensors['ANALOG']['Temperature1']))
  current_indoor_temp = temperature
  nextion.send_raw_nextion_command('insideTemp.txt="'+temperature+'"')
end

def set_outdoor_temp()
  var temperature = str(math.round(get_weather()))
  nextion.send_raw_nextion_command('outsideTemp.txt="'+temperature+'"')
end

def set_initial_thermostat()
  nextion.handle_thermostat()
end

# WARNING: TEMP READER FIX FOR SONOFF NSPANEL, add this to the tasmota console
# to fix temperature readings (much more accurate results after this)
# ADCParam1 2,12400,8800,3950

tasmota.set_timer(100, set_indoor_temp)
tasmota.add_cron("*/10 * * * * *", set_indoor_temp, 'set_indoor_temp')

tasmota.set_timer(2000, set_outdoor_temp)
tasmota.add_cron("*/60 * * * * *", set_outdoor_temp, 'set_outdoor_temp')

tasmota.set_timer(50, set_initial_thermostat)

def hold_desired_temp()
    # TODO: hysteresis is needed so that when the temperature is close to the desired value the relay does not switch on and off
end
