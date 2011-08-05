/**
 * Module dependencies.
 */
require("coffee-script");
var express = require('express');
var form = require('connect-form');

var app = module.exports = express.createServer();

global.mongoose = require('mongoose');
mongoose.connect('mongodb://localhost/nyaa2');

// Configuration

app.configure(function(){
  app.set('views', __dirname + '/views');
  app.set('view engine', 'jade');
  app.use(express.bodyParser());
  app.use(express.methodOverride());
  app.use(express.cookieParser());
  app.use(express.session({ secret: 'himitsu' }));
  app.use(form({keepExtensions: true}));
  app.use(app.router);
  app.use(express.static(__dirname + '/public'));
});

app.configure('development', function(){
  app.use(express.errorHandler({ dumpExceptions: true, showStack: true })); 
});

app.configure('production', function(){
  app.use(express.errorHandler()); 
});

// Load

var torrents = require('./controllers/torrents');
var users = require('./controllers/users');

// Routes
app.get('/', torrents.list);
app.get('/upload', torrents.upload);
app.post('/upload', torrents.upload_post);

app.get('/login', users.login);
app.post('/login', users.login_post);

app.get('/users', users.list);

// Listen
app.listen(3000);
console.log("Express server listening on port %d in %s mode", app.address().port, app.settings.env);

