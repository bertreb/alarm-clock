module.exports = () ->
  
  i2c = require('i2c-bus')
  SerialPort = require('serialport')
  Schedule = require('node-schedule')
  CronJob = require('cron').CronJob
  mqtt = require('mqtt')
  path = require('path')
  winston = require('winston')
  fs = require('fs')
  Moment = require 'moment-timezone'

  class clock

    constructor: () ->

      #
      # set logging
      #
      #filename = path.join(__dirname, 'alarm-clock.log')
    
      winston.format.combine(
        winston.format.colorize()
        winston.format.json()
      )

      consoleOptions =
        level: 'info'
        handleExceptions: true
        json: false
        colorize: true
      @logger = winston.createLogger(
        level: 'info'
        format: winston.format.json()
        defaultMeta: service: 'user-service'
          #
          # - Write to all logs with level `info` and below to `combined.log` 
          # - Write all logs error (and below) to `error.log`.
        transports: [
          new (winston.transports.File)(
            filename: './error.log'
            level: 'error')
          new (winston.transports.File)(filename: './alarm-clock.log')
          new (winston.transports.Console)(consoleOptions)
        ])
      @logger.info("Logger started")

      #
      # read configuration
      #
      @config = {}
      @configFullFilename = path.join __dirname, 'alarm-clock.json'

      @numbertable = [
          0x3F, # 0
          0x06, # 1
          0x5B, # 2
          0x4F, # 3
          0x66, # 4
          0x6D, # 5
          0x7D, # 6
          0x07, # 7
          0x7F, # 8
          0x6F  # 9
          ]
        
      @HT16K33_BLINK_CMD = 0x80
      @HT16K33_DISPLAY_ON = 0x01
      @HT16K33_DISPLAY_OFF = 0x00
      @HT16K33_DISPLAY_BLINK = 0x05
      @TURN_OSCILLATOR_ON = 0x21
      @HT16K33_CMD_BRIGHTNESS = 0xE0
      @dot1 = false
      @dot2 = false
      @dot3 = false
      @timedots = false
      @dots = 0x00
      @setDots(4,true)

      @start(0x70)

      #
      # init the clock
      #
      @time = new Date()
      @time.setTime(Date.now())
      @setDots(4,true)
      @setDisplayTime()
      @minuteTick = new CronJob
        cronTime: '0 */1 * * * *'
        runOnInit: true
        onTick: =>
          @setDisplayTime()
      @minuteTick.start()

      #
      # init WavTrigger
      #
      @port = new SerialPort('/dev/ttyS0', { autoOpen: false, baudRate: 57600 })
      @wtStart()

      #
      # init button
      #
      rpi_gpio_buttons = require('rpi-gpio-buttons')
      @buttonPin = 22
      @button = rpi_gpio_buttons([@buttonPin],{ mode: rpi_gpio_buttons.MODE_BCM })
      @button.on 'clicked', (p) =>
        @logger.info("button clicked")
        if @alarmActive
          @stopAlarm()
          snooze = () =>
            @playAlarm()
          @alarmSnooze +=1
          if @alarmSnooze is 8
            @logger.info("Snoozing stopped")
            @alarmSnooze = 0
            clearTimeout(@snozer)
          else
            @snozer = setTimeout(snooze,300000 - @alarmSnooze*30000)
            @logger.info("Snoozing...")

      # stop alarm and sleep
      @button.on 'pressed', (p)=>
        if @alarmActive
          @stopAlarm()
          @logger.info("Snoozing stopped")
        if @snozer?
          @alarmSnooze = 0
          clearTimeout(@snozer)
          @logger.info("Snoozing stopped")
        @logger.info("button pressed")
        #stop alarm and don't sleep
      @button.on 'clicked_pressed', (p)=>
        @logger.info("button clicked_pressed")
        #stop alarm and don't sleep
      @button.on 'double_clicked', (p) =>
        @logger.info("button double clicked")
        #action

      #
      # init alarm
      #
      @alarmActive = false
      @alarmSnooze = 0

      #
      # init mqtt
      #
      @readConfig()
      .then () =>
        @logger.info("@config: " + @config)
        if @config.alarmclock.state is true
          #_a = @setSchedule(@config.schedule)
          @setDots(1,true)
          _alarm = @setSchedule(@config.schedule)
          d = new Date()
          @logger.info "nextInvo: " + (_alarm.nextInvocation()).getDay() + ", nextDay: " + Moment(d).add(1, 'days').day() + ", toDay: " + Moment(d).day()
          if _alarm.nextInvocation().getDay() is Moment(d).add(1, 'days').day() or _alarm.nextInvocation().getDay() is Moment(d).day()
            @setDots(2,true)
          else
            @setDots(2,false)
          @setDisplayTime()
        options =
          host: @config.mqtt.host
          port: @config.mqtt.port
          username: @config.mqtt.username
          password: @config.mqtt.password
          clientId: "alarmclock"
          protocolVersion: 4
        @mqttClient  = mqtt.connect(options)
        @mqttClient.on 'connect', =>
          @logger.info "Connected to mqtt"
          @mqttClient.subscribe('schanswal/alarmclock/#', (err,granted)=>
            if err?
              @logger.error("Subscribe error: " + err)
            else
              @logger.info("subscribed to " + JSON.stringify(granted))
            )
        @mqttClient.on 'error', (err) =>
          @logger.info ("Mqqt connect error: " + err)
        @mqttClient.on 'message', (topic, message, packet) =>
          @logger.info(JSON.stringify("topic: " + topic + ", message: " + message))
          items = topic.split('/')
          if String items[0] is "schanswal" and String items[1] is "alarmclock"
            @logger.info("mqtt: " + items[2] + ", message: " + message)
            switch String items[2]
              when "alarm"
                if (String message) == "on"
                  @playAlarm()
                else if (String message) == "off"
                  @stopAlarm()
              when "alarmclock"
                if (String message) == "on"
                  @setAlarmclock(true)
                  @logger.info "Alarmclock swtched on"
                else if (String message) == "off"
                  @setAlarmclock(false)
                  @logger.info "Alarmclock swtched off"
                @updateConfig()
            switch String items[2]
              when "alarmtime"
                try
                  data = JSON.parse(message)
                  @config["schedule"] = data
                  @setSchedule(data)
                  @updateConfig()
                catch err  
                  @logger.error("ERROR schedule not set, error in JSON.parse mqtt message,  " + err)
      .catch (err) =>
        @logger.error "error: " + err
        return

    setAlarmclock: (_state) =>
      @config.alarmclock.state = _state
      if _state is false
        @setDots(1,false)
        @setDots(2,false)
        if @alarm?
          @alarm.cancel()
          @logger.info "Schedule cancelled"
      else
        @setDots(1,true)
        _alarm = @setSchedule(@config.schedule)
        d = new Date()
        if _alarm.nextInvocation().getDay() is Moment(d).add(1, 'days').day() or _alarm.nextInvocation().getDay() is Moment(d).day()
          @setDots(2,true)
        else
          @setDots(2,false)
      @setDisplayTime()
      @updateConfig()


    setSchedule: (data) =>
      @logger.info "data: " + JSON.stringify(data)
      if (Number data.hour) >= 0 and (Number data.hour) <= 23 and (Number data.minute) >= 0 and (Number data.minute) <= 59
        if @alarm? then @alarm.cancel()
        rule = new Schedule.RecurrenceRule()
        rule.dayOfWeek = [data.days]
        rule.hour = Number data.hour
        rule.minute = Number data.minute
        if @alarm? then @alarm.cancel()
        @logger.info "Schedule set for " + data.hour  + ":" + data.minute + ", on days: " + data.days
        @alarm = Schedule.scheduleJob(rule,() =>
          @playAlarm()
          @logger.info "Next alarm: " + @alarm.nextInvocation()
          d = new Date()
          if @alarm.nextInvocation().getDay() is Moment(d).add(1, 'days').day()
            @setDots(2,true)
          else
            @setDots(2,false)
          @setDisplayTime()
          )
        @logger.info "next1: " + @alarm.nextInvocation().toString()
        return @alarm

    readConfig: () =>
      return new Promise ((resolve, reject) =>           
        if !fs.existsSync(@configFullFilename)
          @logger.error "Config doesn't exists!" 
          reject("Config doesn't exists")
        else
          fs.readFile(@configFullFilename, 'utf8', (err, data) =>
            if !(err)
              try
                @config = JSON.parse(data)
                #@logger.error "Config read: " + JSON.stringify(@config)
                resolve()
              catch err
                @logger.error "Config JSON not valid: " + err
                reject("Config JSON not valid")
            else
              @logger.error "Config doesn't exists: " + err
              reject("Config doesn't exists")
          )
        )

    updateConfig: () =>
      try
        fs.writeFileSync @configFullFilename, JSON.stringify(@config,null,2)
      catch err
        if not err
          @logger.info "Config updated"
        else
          @logger.error "Config not updated"

    stopAlarm: () =>
      @alarmActive = false
      @wtStop()
      @setDisplayState(1)
      @setDisplayTime()

    playAlarm: () =>
      @alarmActive = true
      @wtSolo(4)
      @setDisplayState(2)
      @setDisplayTime()
      maxPlayTime = () =>
        @button.emit 'clicked', @buttonPin

      setTimeout(maxPlayTime, 30000)

    start: (_addr) =>
      @HT16K33_ADDR = _addr
      @i2c1 = i2c.open(1, (err) => 
        if err? then throw err
        turnOnBuffer = Buffer.alloc(1)
        turnOnBuffer[0] = @TURN_OSCILLATOR_ON
        @i2c1.i2cWrite(@HT16K33_ADDR,turnOnBuffer.length, turnOnBuffer, (err, bytesWritten, buffer) =>
          if err? then throw err
          @setDisplayState(1)
          @setBrightness(1)
          @minuteTick.start()
         )
      )

    setDisplayState: (_state) =>
      switch _state
        when 0
          blinkbuffer = Buffer.alloc(1);
          blinkbuffer[0] = @HT16K33_BLINK_CMD | @HT16K33_DISPLAY_OFF;
          @i2c1.i2cWrite(@HT16K33_ADDR, blinkbuffer.length, blinkbuffer, (err, bytesWritten, buffer) =>
            if err?
              @logger.error(err)
          )
        when 2
          blinkbuffer = Buffer.alloc(1);
          blinkbuffer[0] = @HT16K33_BLINK_CMD | @HT16K33_DISPLAY_BLINK;
          @i2c1.i2cWrite(@HT16K33_ADDR, blinkbuffer.length, blinkbuffer, (err, bytesWritten, buffer) => 
            if err?
              @logger.error(err)
          )
        else
          blinkbuffer = Buffer.alloc(1);
          blinkbuffer[0] = @HT16K33_BLINK_CMD | @HT16K33_DISPLAY_ON;
          @i2c1.i2cWrite(@HT16K33_ADDR, blinkbuffer.length, blinkbuffer, (err, bytesWritten, buffer) => 
            if err?
              @logger.error(err)
          )

    setBrightness: (_brightness) =>
      brightnessbuffer = Buffer.alloc(1);
      if _brightness < 0 or _brightness>15 then _brightness = 0
      brightnessbuffer[0] = @HT16K33_CMD_BRIGHTNESS | _brightness;
      @i2c1.i2cWrite(@HT16K33_ADDR, brightnessbuffer.length, brightnessbuffer, (err, bytesWritten, buffer) => 
        if err?
          @logger.error(err)
      )

    setDisplayTime: () =>
      d = Date.now()
      @time.setTime(d)
      _hours = @time.getHours()
      _minutes = @time.getMinutes()
      if _hours < 0 or _hours > 23 then _hours = 23
      if _minutes < 0 or _minutes > 59 then minutes = 59
      if _hours < 10
        _digit1 = 0
        _digit2 = Number (String _hours)[0]
      else
        _digit1 = Number (String _hours)[0]
        _digit2 = Number (String _hours)[1]
      if _minutes < 10
        _digit3 = 0
        _digit4 = Number (String _minutes)[0]
      else
        _digit3 = Number (String _minutes)[0]
        _digit4 = Number (String _minutes)[1]

      displaybuffer = Buffer.alloc(11,0x00)
      displaybuffer[1] = @numbertable[_digit1]
      displaybuffer[3] = @numbertable[_digit2]
      displaybuffer[5] = @dots
      displaybuffer[7] = @numbertable[_digit3]
      displaybuffer[9] = @numbertable[_digit4]      
      @i2c1.i2cWrite(@HT16K33_ADDR, displaybuffer.length, displaybuffer, (err, bytesWritten, buffer) =>
          #@logger.info('Display written ' + bytesWritten)
      )

    setDots: (_nr, _state) =>
      switch _nr
        when 1
          @dot1 = _state 
        when 2
          @dot2 = _state 
        when 3
          @dot3 = _state 
        when 4
          @timedots = _state
      @dots = 0x00 | (if @dot1 then 0x08) | (if @dot2 then 0x04) | (if @dot3 then 0x10) | (if @timedots then 0x03)

    wtStart: () =>
      _WT_GET_VERSION = [0xF0,0xAA,0x05,0x01,0x55]
      @port.open((err) =>
        if err
          @logger.info('Error opening port: ', err.message)
        @wtPower(true)
        @wtVolume(-10)
        # play startup tune
        @wtSolo(99)
      )

    wtPower: (_state) =>
      _WT_AMP_POWER = [0xF0,0xAA,0x06,0x09,0x00,0x55]
      if _state
        _WT_AMP_POWER[4] = 0x01
        @port.write(Buffer.from(_WT_AMP_POWER))
      else
        @port.write(Buffer.from(_WT_AMP_POWER))

    wtVolume: (_volume) =>
      _WT_VOLUME = [0xF0,0xAA,0x07,0x05,0x00,0x00,0x55]
      if _volume < -70 then _volume = -70 
      if _volume > 4 then _volume = 4
      _WT_VOLUME[4] = _volume & 0xFF
      _WT_VOLUME[5] = (_volume & 0xFF00) >> 8
      @port.write(Buffer.from(_WT_VOLUME))

    wtSolo: (_track) => 
      _WT_TRACK_SOLO = [0xF0,0xAA,0x08,0x03,0x00,0x00,0x00,0x55]
      _WT_TRACK_SOLO[5] = _track & 0xFF
      _WT_TRACK_SOLO[6] = (_track & 0xFF00) >> 8
      @port.write(Buffer.from(_WT_TRACK_SOLO))

    wtStop: () => 
      _WT_STOP_ALL = [0xF0,0xAA,0x05,0x04,0x55]
      #_WT_TRACK_STOP = [0xF0,0xAA,0x08,0x03,0x04,0x00,0x00,0x55]
      #_WT_TRACK_STOP[5] = _track & 0xFF
      #_WT_TRACK_STOP[6] = (_track & 0xFF00) >> 8
      @port.write(Buffer.from(_WT_STOP_ALL))
    
  return new clock







