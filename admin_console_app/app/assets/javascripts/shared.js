$(document).ready(function(){
  $('.busy-trigger').click(function(){
    $(this).addClass('disabled');
    $('body').addClass('busy'); });
  $('a.expander').on('click', function(){
    $(this).toggleClass('collapsed');
    $(this).toggleClass('expanded'); });
});

var currentPageURL = location.protocol + '//' + location.hostname + (location.port ? ':'+location.port: '');
function loopTillRebootFinished(){
  $('body').addClass('busy');

  setTimeout(function() {
    $.ajax({
      url: currentPageURL,
      type: 'HEAD',
      complete: function(response) {
        if ( response.status < 400 ) {
          $('#rebootingModal').modal('hide');
          $('body').removeClass('busy');
          // The following is a bit crap and needs to be refactored. We're using this partial in two places:
          //   the dashboard, and the registration wizard.
          // The Continue button is present when this partial is rendered during the registratinon process.
          // On the dasboard (where there is not Continue button) we just want to reload the page
          if ( $('button:contains(Continue)').html() ){
            $('button:contains(Continue)').removeClass('disabled');
            $('button:contains(Continue)').trigger('click'); }
          else {
            location.reload(); }
        }
        else
          loopTillRebootFinished(); } }); },
    5000 ); }


function playAnimation($elem) {
  $elem.before($elem.clone(true));
  var $newElem = $elem.prev();
  $elem.remove();
  $newElem.addClass("play animated");
  // The 1600 timeout needs to match whatever the CSS animation time is.
  // Note, this is only needed to keep IE from replaying the animation when visibility is toggled
  setTimeout(function(){ $newElem.removeClass("play animated"); }, 1600);
}


function selectifyDropdown(element){

  $(element + " .dropdown-menu li a").click(function(e){
    e.preventDefault();
    var selectedText = $(this).text()
    var button = $(this).parents('.input-group-btn').find('button[data-toggle="dropdown"]');
    var fieldToUpdate = button.parents('.input-group-btn').data('target');
    var selectedValue = $(this).data('value');

    $( fieldToUpdate ).val(selectedValue || selectedText);

    button.html(selectedText + ' <span class="caret"></span>');

    var parentForm = $(element).parents('form');
    if ( parentForm &&
         (parentForm.find('input[type="submit"], button[type="submit"]').length === 0)){
      var submitUrl = parentForm.attr('action');
      var submitMethod = parentForm.attr('method') || 'PUT';

      $.ajax({
        url: submitUrl,
        type: submitMethod,
        data: parentForm.serialize(),
        success: function(data) {
          var success_div = $( 'div[data-status-for=' + $(fieldToUpdate).attr('id') +  ']');
          playAnimation(success_div);
          $( 'label[for=' + $(fieldToUpdate).attr('id') + ']' )
        },
        error: function(){
          alert("Unable to change log level"); } });
    }
  });
}

function ajaxifyCheckbox(element){
  var parentForm = $(element).parents('form');
  var submitUrl = parentForm.attr('action');
  var submitMethod = parentForm.attr('method') || 'PUT';
  var selectedValue = $(element).val();

  $(element).change(function(){

    $('body').addClass('busy');
    $.ajax({
      url: submitUrl,
      type: submitMethod,
      data: parentForm.serialize(),
      success: function(data) {
        var success_div = $( 'div[data-status-for=' + $(element).attr('id') + ']' );
        playAnimation(success_div);
      },
      error: function(){
        alert("Unable to change log level"); },
      complete: function(){
        $('body').removeClass("busy");} });

  });
}
