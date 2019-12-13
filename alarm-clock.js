#!/usr/bin/env node

require('./node_modules/coffee-cache/lib/coffee-cache.js').setCacheDir('.jscache/');
var clock = require('./alarm-clock');
console.log(clock);
console.log('Application starting...')
var app = new clock();
