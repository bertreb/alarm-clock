# alarm-clock
mqtt controllable alarm-clock

Installation:
- prepare system with node/npm and connected button
- choose root directory (/home/pi or ...)
- install 'alarm-clock' via git clone https://github.com/bertreb/alarm-clock.git
- cd alarm-clock
- npm install
- edit config-default.json with your mqtt, buttonPin and default schedule info and save as config.json
- check your node path in alarm-clock.template and install the  template as systemd service
- run command 'sudo service alarm-clock start' or reboot
