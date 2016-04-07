// Place all the behaviors and hooks related to the matching controller here.
// All this logic will automatically be available in application.js.

function initLogger(){
  var dispatcher = new WebSocketRails('localhost:3001/websocket');

  dispatcher.on_open = function(){
    dispatcher.trigger('logs.start_tailing');
    console.log("connection opened");}

  dispatcher.on_close = function(){
    dispatcher.trigger('logs.stop_tailing');
    console.log("connection closed");}

  dispatcher.bind('logs.new_message', function(log_msg) {
    $('#log_console').append(log_msg);
    $('#log_console').append('<br>');
    $('#log_console').animate({scrollTop: $('#log_console').prop("scrollHeight")}, 500); });
}


function populateLogLevels(select){

  $.ajax({
    url: 'logger/level',
    type: 'GET',
    success: function(data) {
      $.each(data.levels, function(index,level){
        $(select + ' ul').append('<li><a href="#">' + level + '</a></li>'); });
      if ( data.selected ) {
        $(select + ' button').html(data.selected + ' <span class="caret"></span>');
        $( $(select).data('target') ).val(data.selected); }
      selectifyDropdown(select);
    },
    error: function(data){
      console.log(data.error);} });
}
