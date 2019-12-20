module.exports = () ->

  Promise = require('bluebird')
  i2c = require('i2c-bus')
  SerialPort = require('serialport')
  Schedule = require('node-schedule')
  CronJob = require('cron').CronJob
  mqtt = require('mqtt')
  path = require('path')
  winston = require('winston')
  fs = require('fs')
  Moment = require('moment-timezone')
  dateformat = require('dateformat')
  SunCalc = require('suncalc')
  rpi_gpio_buttons = require('rpi-gpio-buttons')

  class AlarmClock

    constructor: () ->

      #
      # set logging
      #
      logfile = path.join(__dirname, 'alarm-clock.log')

      @logger = winston.createLogger({
        level: 'debug'
        format: winston.format.combine(
          winston.format.timestamp(),
          winston.format.colorize(),
          winston.format.printf((info) =>
            ts = dateformat(info.timestamp, "HH:MM:ss:l")
            return "#{ts} [#{info.level}] #{info.message}"
          )
        )
        transports: [
          #new winston.transports.Console({
          #  format: winston.format.combine(winston.format.colorize({level:true}))
          #}),
          new winston.transports.File({
            filename: logfile,
            format: winston.format.uncolorize({level:false})
          })
        ]
      })
      if (process.env.NODE_ENV isnt 'production')
        @logger.add(new winston.transports.Console({
          format: winston.format.combine(winston.format.colorize({level:true}))
        }))

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

      dateformat.i18n =
        dayNames: [
          'Zon', 'Maa', 'Din', 'Woe', 'Don', 'Vri', 'Zat',
            'Zondag', 'Maandag', 'Dinsdag', 'Woensdag', 'Donderdag', 'Vrijdag', 'Zaterdag'
        ],
        monthNames: [
          'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dec',
            'Januari', 'Februari', 'Maart', 'April', 'Mei', 'Juni', 'Juli', 'Augustus', 'September', 'Oktober', 'November', 'December'
        ],
        timeNames: [
          'a', 'p', 'am', 'pm', 'A', 'P', 'AM', 'PM'
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
      @startDisplay(0x70)

      #
      # init alarm
      #
      @alarmActive = false
      @alarmSnooze = 0

      afterBootDisplay = () =>
        @setDisplayState(1)
        @setAlarmclock()
        @setDisplayTime()
        @minuteTick = new CronJob
          cronTime: '0 */1 * * * *'
          onTick: =>
            @setDisplayTime()
        @minuteTick.start()
        @dayTick = new CronJob
          cronTime: '0 1 0 * * *'
          onTick: =>
            @setAlarmclock()
            @logger.info "Midnight new day setAlarmClock"
            @setDisplayTime()
        @dayTick.start()

      @afterBootTimer = setTimeout(afterBootDisplay,5000)

      #
      # init WavTrigger
      #
      @port = new SerialPort('/dev/ttyS0', { autoOpen: false, baudRate: 57600 })
      @wtStart()
      @wtDefaultVolume = -10
      @wtVolume(@wtDefaultVolume)

      @readConfig()
      .then () =>
        #
        # init mqtt
        #
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
              @mqttClient.publish("schanswal/alarmclock/alarmclock/status", (if @config.alarmclock.state then "on" else "off"), (err) =>
                if err?
                  @logger.info "error publishing state: " + err
              )
            )
        @mqttClient.on 'error', (err) =>
          @logger.info ("Mqtt connect error: " + err)
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
              when "brightness"
                @setBrightness(Number message)
                @logger.info "Brightness set to #{message}"
              when "alarmclock"
                if (String message) == "on"
                  @setAlarmclock(true)
                  @logger.info "Alarmclock switched on"
                else if (String message) == "off"
                  @setAlarmclock(false)
                  @logger.info "Alarmclock switched off"
                @setDisplayTime()
                @updateConfig()
              when "alarmtime"
                try
                  data = JSON.parse(message)
                  @config["schedule"] = data
                  @setAlarmclock()
                  @setDisplayTime()
                  @updateConfig()
                catch err
                  @logger.error("ERROR schedule not set, error in JSON.parse mqtt message,  " + err)
              else
                @logger.info "other message received: " + message

        #
        # button definitions
        #
        @buttonPin = @config.alarmclock.buttonPin
        @button = rpi_gpio_buttons([@buttonPin],{ mode: rpi_gpio_buttons.MODE_BCM })
        @button.setTiming({debounce: 50, clicked: 400, pressed: 400 })
        @button.on 'clicked', (p) =>
          @logger.info("button clicked")
          if @alarmActive
            @stopAlarm()
            @blinkDot(true)
            snooze = () =>
              @alarmActive = true
              @playAlarm()
            @alarmSnooze +=1
            if @alarmSnooze is 8
              @button.emit 'pressed', p
              @logger.info("Snoozing stopped")
              @alarmSnooze = 0
              clearTimeout(@snozer)
            else
              @snozer = setTimeout(snooze,300000)
              @logger.info("Snoozing...")
          else if @alarmSnooze is 0
            @mqttClient.publish("schanswal/alarmclock/button", "1", (err) =>
              if err?
                @logger.info "error publishing state: " + err
            )
        @button.on 'pressed', (p)=>
          # stop alarm and sleep
          if @alarmActive
            @stopAlarm()
            @logger.info("Snoozing stopped")
          if @snozer?
            @alarmSnooze = 0
            clearTimeout(@snozer)
            @logger.info("Snoozing stopped")
          @blinkDot(false)
          @setAlarmclock()
          @logger.info("button pressed")
          #stop alarm and don't sleep
        @button.on 'clicked_pressed', (p)=>
          @logger.info("button clicked_pressed")
          #stop alarm and don't sleep
        @button.on 'double_clicked', (p) =>
          @logger.info("button double clicked")
          #action

      .catch (err) =>
        @logger.error "error: " + err
        return

    setAlarmclock: (_s) =>
      if _s?
        _state = _s
        @config.alarmclock.state = _s
      else
        _state = @config.alarmclock.state
      if _state is false
        @setDots(1,false)
        @setDots(2,false)
        if @alarm?
          @alarm.cancel()
          @logger.info "Alarm cancelled"
      else
        @setDots(1,true)
        _alarm = @setSchedule(@config.schedule)
        d = new Date()
        if (@alarm.nextInvocation().getDay() == Moment(d).add(1, 'days').day()) or
          (@alarm.nextInvocation().getDay() == Moment(d).day() and
            @alarm.nextInvocation().getHours() >= Moment(d).hour() and
              @alarm.nextInvocation().getMinutes() > Moment(d).minute())
          @logger.info "Next alarm: " + @alarm.nextInvocation()
          @mqttClient.publish("schanswal/alarmclock/nextalarm", dateformat(@alarm.nextInvocation(), "dddd H:MM, d-m-yyyy"), (err) =>
            if err?
              @logger.info "error publishing next alarmtime: " + err
          )
          @setDots(2,true)
        else
          @setDots(2,false)


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
          @mqttClient.publish("schanswal/alarmclock/nextalarm", dateformat(@alarm.nextInvocation(), "dddd H:MM, d-m-yyyy"), (err) =>
            if err?
              @logger.info "error publishing next alarmtime: " + err
          )
          d = new Date()
          if @alarm.nextInvocation().getDay() is Moment(d).add(1, 'days').day()
            @setDots(2,true)
            @setDisplayTime()
          else
            @setDots(2,false)
            @setDisplayTime()
          )
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
      _track = Math.floor((Math.random() * 4) + 2)
      @wtSolo(_track)
      @_volume = -40
      fade = () =>
        @_volume += 1
        @wtVolume(@_volume)
        @fadeTimer = setTimeout(fade,1000) if @_volume < @wtDefaultVolume
      fade()
      @setDisplayState(2)
      @setDisplayTime()
      maxPlayTime = () =>
        @button.emit 'clicked', @buttonPin
      setTimeout(maxPlayTime, 60000)

    startDisplay: (_addr) =>
      @HT16K33_ADDR = _addr
      @i2c1 = i2c.open(1, (err) =>
        if err? then throw err
        turnOnBuffer = Buffer.alloc(1)
        turnOnBuffer[0] = @TURN_OSCILLATOR_ON
        @i2c1.i2cWrite(@HT16K33_ADDR,turnOnBuffer.length, turnOnBuffer, (err, bytesWritten, buffer) =>
          if err? then throw err
          @setDisplayState(2)
          d = new Date()
          times = SunCalc.getTimes(d, 53.0128, 6.5556)
          if Moment(d).isAfter(times.sunrise) and Moment(d).isBefore(times.sunsetStart)
            @setBrightness(4)
          else
            @setBrightness(0)
          @setDisplayTime(0,0)
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

    setDisplayTime: (_h,_m) =>
      try
        _time = new Date()
        _hours = if _h? then _h else _time.getHours()
        _minutes = if _m? then _m else _time.getMinutes()
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
      catch err
        @logger.info "eeror in setDisplay: " + err


    blinkDot: (_enabled) =>
      @blinkOn = false
      @dotstate = false
      if @blinkDotTimer? then clearTimeout(@blinkDotTimer)
      if _enabled
        @blinkOn = true
        dotBlinking = () =>
          @dotState = !@dotState
          @setDots(2,@dotState)
          @setDisplayTime()
          @blinkDotTimer = setTimeout(dotBlinking,1000) unless @blinkOn is false
        dotBlinking()
      else
        @setDots(2,false)
        @setDisplayTime()
        @blinkOn = false

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

    clearDisplay: () =>
      displaybuffer = Buffer.alloc(11,0x00)
      @i2c1.i2cWrite(@HT16K33_ADDR, displaybuffer.length, displaybuffer, (err, bytesWritten, buffer) =>
        #@logger.info('Display written ' + bytesWritten)
      )

    wtStart: () =>
      _WT_GET_VERSION = [0xF0,0xAA,0x05,0x01,0x55]
      @port.open((err) =>
        if err
          @logger.info('Error opening port: ', err.message)
        @wtPower(true)
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

    wtFade: (_track) =>
      _WT_FADE = [0xF0,0xAA,0x0C,0x0A,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x55]
      _volume = 0
      _time = 10000
      _WT_FADE[4] = _track & 0xFF
      _WT_FADE[5] = (_track & 0xFF00) >> 8
      _WT_FADE[6] = _volume & 0xFF
      _WT_FADE[7] = (_volume & 0xFF00) >> 8
      _WT_FADE[8] = _time & 0xFF
      _WT_FADE[9] = (_time & 0xFF00) >> 8
      #_WT_FADE[10] = 0x00
      @port.write(Buffer.from(_WT_FADE))

    wtStop: () =>
      _WT_STOP_ALL = [0xF0,0xAA,0x05,0x04,0x55]
      #_WT_TRACK_STOP = [0xF0,0xAA,0x08,0x03,0x04,0x00,0x00,0x55]
      #_WT_TRACK_STOP[5] = _track & 0xFF
      #_WT_TRACK_STOP[6] = (_track & 0xFF00) >> 8
      @port.write(Buffer.from(_WT_STOP_ALL))

    destroy:() =>
      return new Promise( (resolve, reject) =>
        @port.close()
        if @alarm? then @alarm.cancel()
        @minuteTick.stop()
        @dayTick.stop()
        if @snozer? then clearTimeout(@snozer)
        @button.removeAllListeners()
        @mqttClient.removeAllListeners()
        if @afterBootTimer? then clearTimeout(@afterBootTimer)
        if @blinkDotTimer? then clearTimeout(@blinkDotTimer)
        if @fadeTimer? then clearTimeout(@fadeTimer)
        resolve()
      )

  return new AlarmClock
