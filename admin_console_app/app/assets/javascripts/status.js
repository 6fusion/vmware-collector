// Place all the behaviors and hooks related to the matching controller here.
// All this logic will automatically be available in application.js.

function refreshDatabaseStats(){
  // Skip refreshing if the pane is not visible
  if ( $('#Status').hasClass('active') ){
    $('html, body').css("cursor", "wait");

    $.getJSON('status/database', function(db_stats){
      $('#database_queued_metrics').text(db_stats.queued_metrics);
      $('#database_size').text(db_stats.size);
    })
      .always(function() {
        $('html, body').css("cursor", "default");
      });
  }
}

function refreshApplianceStats(){
  // Skip refreshing if the pane is not visible
  if ( $('#Status').hasClass('active') ){
    $('html, body').css("cursor", "wait");

    $.getJSON('status/appliance', function(stats){
      $('#appliance_load').text(stats.load);
      $('#appliance_uptime').text(stats.uptime);
      $('#appliance_disk_used').text(stats.disk_used);
      $('#appliance_disk_size').text(stats.disk_size + ' GiB');
      $('#appliance_disk_percent_used').text( ((stats.disk_used / stats.disk_size) * 100).toFixed(0) +  ' %');
    })
      .always(function() {
        $('html, body').css("cursor", "default");
      });
  }
}


function refreshServiceStates(){
  // Skip refreshing if the pane is not visible
  if ( $('#Status').hasClass('active') ){
    var enable = 'status/enable';
    var disable = 'status/disable';

    $('html, body').css("cursor", "wait");

    $.getJSON('status/services', function(data){
      $.each(data, function(index,item){
        var row = $('div[data-row-for="' + item.name + '"]');
        $('div[data-status-for="' + item.name + '"]').text(item.status);

        var action = "";
        if ( !((item.name == 'Meter Console') ||
               (item.name == 'Database')) ){
          if ( item.status == 'paused' ){
            $(row).find('a.container_action.pause').hide();
            $(row).find('a.container_action.resume').show();}
          else{
            $(row).find('a.container_action.resume').hide();
            $(row).find('a.container_action.pause').show();}
        }
      });
    })
      .always(function() {
        $('html, body').css("cursor", "default");
      });
  }
}


function refreshHealthStats(){

  if ( $('#Status').hasClass('active') ){
    $('html, body').css("cursor", "wait");

    $.getJSON('status/health', function(data){
      $.each(data, function(key,value){
        $( '#health_' + key ).text(value);
      });

    })
      .always(function() {
        $('html, body').css("cursor", "default");
      });
  }


}

function togglifyActionLinks(){

  $('a.container_action').click(function(){
    var action = $(this).data('action');
    var container = $(this).parent('div').data('action-for');

    $('html, body').css("cursor", "wait");

    $.ajax({
      method: 'PUT',
      url: 'service/' + action,
      data: { container: container },
      success: function(){
        refreshServiceStates();},
      error: function(error){
        console.log(error);
      },
      complete: function(){
        $('html, body').css("cursor", "default");
      }
    });
  });
}
