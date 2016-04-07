/* Methods for the configure_network view */

/* Automatic/Static selector helper */
function initNetworkToggles(){
  $('#networkToggleLegend a').on('click', function(event) {

    $( $( $('#networkToggleLegend a').not($(this))).data('target')).hide();
    $( $('#networkToggleLegend a').not($(this)) ).removeClass('selected');

    $( $(this).data('target') ).show();
    $( $(this) ).addClass('selected');
    // When a tab is selected, update a hidden field so we can pass the type to rails
    if ( $(this).text() == 'Static' ) {
      $("#networking_type").val("static"); }
    else {
      $("#networking_type").val("automatic"); }
  });
}

function vcenterToStaticWarning(event, original_settings){
  /* We only need to alert the user if they've
     a) changed from auto to static
     b) actually modified the static settings */
  if ( ($("#networking_type").val() == "static") &&
       networkingFormChanged(original_settings)  ){
    // Move the submit functionality from the Continue button to the Understood button in the warning modal
    $('#understoodButton').click(function(){
      $('form').submit();});
    event.preventDefault();

    $('#vcenterToStaticWarning').modal('show');
  }
}
/* Helper for the vcenterToStaticWarning method above */
function networkingFormChanged(original){
  ( original['ip_address'] != $('#networking_ip_address').val() ) ||
  ( original['netmask'] != $('#networking_netmask').val() ) ||
  ( original['gateway'] != $('#networking_gateway').val() ) ||
  ( original['dns'] != $('#networking_dns').val() )
}


/* This method tries to be clever about getting the user back into the wizard after they've changed
   their network settings (and therefore, the address used to access the wizard, possibly) */
function urlAfterReboot(){
  var path = "/registration/configure_uc6";

  if ( location.hostname.match(/\b(?:\d+\.){3}\d+/) ) {
    return $('#reboot_prompt').data('refresh-host') + path;  }
  else{
    return location.protocol + '//' + location.hostname + (location.port ? ':'+location.port: '') + path;  }
}

var registrationCheckCount = 0;
function checkRegistrationPage(){
  // I think 35 works out to a wait of ~ 70 seconds (reboot + mongo ~ 70 seconds)
  if ( registrationCheckCount > 35 ) {
    return false; }

  setTimeout(function() {
    $.ajax({
      url: urlAfterReboot(),
      type: 'HEAD',
      success: function(data) {
        continueFromReboot(); },
      error: function(){
        registrationCheckCount++;
        if ( registrationCheckCount > 35 ){
          $('#reboot_started').toggle();
          $('#reboot_failed').fadeIn();
        }
        else{
          checkRegistrationPage();}
      },
      timeout: 2000
    })
  }, 2000);
}

function triggerReboot(){
  $('#reboot_prompt').toggle();
  $('#reboot_started').fadeIn();

  $.ajax({
    url: $('#reboot_prompt').data('reboot-uri'),
    method: 'PUT'});

  checkRegistrationPage();
}
function triggerShutdown(){
  $.ajax({
    url: $('#reboot_prompt').data('shutdown-uri'),
    method: 'PUT'});
}

function continueFromReboot(){
  window.location.href = urlAfterReboot(); }


// Meter intialization/websocket methods
var dispatcher;

function initUC6SyncWebSocket(){
  dispatcher = new WebSocketRails($('#uc6_sync_steps').data('uri'));

  if ( ! dispatcher ){
    alert("Unable to intialize web socket for upgrade.") }

  dispatcher.bind('uc6_sync.new_message', function(action) {

    if ( action.response ) {
      $('#' + action.step + ' div.response').text(action.response) }

    if ( action.status == 'in_progress' ) {
      $('#' + action.step + ' i').removeClass();
      $('#' + action.step + ' i').addClass('fa fa-cog fa-spin'); }
    else if ( action.status == 'success' ) {
      $('#' + action.step + ' i').removeClass();
      $('#' + action.step + ' i').addClass('fa fa-check-circle-o');
    }
    else if ( action.status == 'abort' ) {
      $('#' + action.step + ' i').removeClass('fa-spin');
    }
    else if ( action.status == 'error' ) {
      $('<div class="step_error">' + action.error + '</div>').insertAfter( $('#' + action.step ) );
    }
    else if ( action.status == 'skip' ) {
      $('#' + action.step).addClass('skip');
    }
  });

  dispatcher.bind('uc6_sync.finished', function(msg) {
    if ( msg ) {
      $('#uc6_sync_finished_message').html(msg); }
    $('#uc6_sync_continue_button').removeClass('disabled');
  });
}

/* should be moved to shared.js, but need to figure out where to put var dispatcher; */
function initUpgradeWebSocket(){
  dispatcher = new WebSocketRails($('#downloadProgressModal').data('uri'));

  if ( ! dispatcher ){
    alert("Unable to intialize web socket for upgrade.") }

  dispatcher.bind('upgrade.start', function(data) {
    $('body').addClass('busy');
  });

  dispatcher.bind('upgrade.status', function(data) {
    var status_div;
/*
    if ( data.image ){
      var href_target = data.image.replace('/',''); //!! redundant with below
      status_div = $('#' + href_target ).append('<div style="margin-left: 20px;"></div>'); }
    else{
      status_div = $('#upgradeStatus') }


    if ( data.type == 'error' ){
      $(status_div).html('<span style="color:red; margin-left: 20px">' + data.message + '</span>'); }
    else{
      $(status_div).html('<span>' + data.message + '</span><br>'); }
*/
    console.log(data);
  });

  dispatcher.bind('upgrade.new_message', function(data){
    if ( $('#downloadModalStatus').is(':visible') ){
      $('#downloadModalStatus').hide(); // change to blank out text, reuse, ranem status
      $('#downloadProgressModal .modal-body').fadeIn().removeClass('hidden'); }

    var href_target = data.image.replace('/','');
    var row = document.getElementById(href_target + '_progress');

    if ( ! row ){
      var ellipsisTemplate = $('#ellipsisTemplate').clone();
      $(ellipsisTemplate).removeAttr('id');
      $(ellipsisTemplate).addClass('loadingEllipsis');
      $(ellipsisTemplate).show();

      var progress_row = $('#progress_step_row_template').clone();
      $(progress_row).attr('id', href_target + '_progress');
      $(progress_row).find('.panel-heading').data('parent', href_target + "_progress");
      $(progress_row).find('.panel-heading').attr('href', '#' + href_target);
      $(progress_row).find('.panel-collapse').attr('id', href_target );

      $(progress_row).find('.panel-title a').html('Downloading ' + data.image);
      $(progress_row).find('.panel-title a').append(ellipsisTemplate);
      $(progress_row).show();
      $('#downloadProgressModal div.modal-body').append( progress_row );
      row = progress_row; }

    if ( data.status == 'complete' ) {
      var ellipsis = $(row).find('.loadingEllipsis');
      ellipsis.removeClass('loadingEllipsis');
      ellipsis.append('complete');
      $(row).find('.panel-collapse').collapse('hide');  }

    if ( data.layer_id ) {
      if ( $(row).find('#' + data.layer_id ).length ){
        if ( data.layer_id ){
          $('#' + data.layer_id + ' .progress-bar span').text(data.status);
          if ( data.percent_complete ){
            $('#' + data.layer_id + ' .progress-bar').attr('style', 'width:' + data.percent_complete + '%');
            if ( data.percent_complete == '100' ){
              $('#' + data.layer_id + ' .progress-bar').removeClass('active'); }
          }
        }
      }
      else {
        var progress_bar = $('#progress_bar_template').clone();
        $(progress_bar).find('.download-bar-label').text(data.layer_id);
        $(progress_bar).find('.progress-bar span').text(data.status);
        $(progress_bar).attr('id', data.layer_id);
        $(progress_bar).find('.progress-bar').attr('style', 'width:' + data.percent_complete + '%');
        $('#' + data.layer_id + ' .progress-bar').attr('style', 'width:' + data.percent_complete + '%');
        $(progress_bar).show();
        var panel_body = $(row).find('.panel-body');
        panel_body.append( progress_bar );
        var height = 0;
        $('.panel-body').each(function(i, elem){ height += $(elem).prop('scrollHeight') ; });
        $('.modal-body').animate({ scrollTop: height }, 300);
      }
    }
  });

  dispatcher.bind('upgrade.finished', function(msg) {
    // Some of these seem redundant with above code, but actually can be useful for getting UI recovered from error/unexpected code paths
    $('#downloadProgressModal .panel-collapse').collapse('hide');
    $('.loadingEllipsis').hide();
    $('.progress-bar').removeClass('active');
    $('body').addClass('busy');
    $('#upgrade_reboot_button').removeClass("disabled");
    $('body').removeClass('busy');
  });
}

function startMeterUpgrade(){
  $('#update_available_link').addClass('disabled');
  dispatcher.trigger('upgrade.pull');}


function startMeterSync(){
  $('#uc6_sync_init').hide();
  $('#uc6_sync_steps').fadeIn();

  dispatcher.trigger('uc6_sync.start');
}


function continueWithReset(resetChoice){
  $('#reset_meter_selection').val(resetChoice);
  $('#reset_meter_selection').parents('form').submit();
}

function lastChanceBeforeReset(){
  $('#confirm-reset').modal('show');
}
