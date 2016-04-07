/* figure out how to consolidate this with the similar method in the registration */
function putifyPutLinks(){
  $('.put-link').each(function(){
    $(this).click(function(e){
      e.preventDefault();
      $('html, body').css("cursor", "wait");
      $.ajax({
        type: 'PUT',
        dataType: 'json',
        context: this,
        url: $(this).attr('href') })
        .success(function(){
          /* Provides a hook for links like "pause collection" - so we can pass in the refresh method to call and make things look responsive */
          if ( $(this).data('callback') ){
            eval('(' + $(this).data('callback') + ')'); }})
        .always(function() {
          $('html, body').css("cursor", "default"); });
    });});
}

function saveTabsForRefresh(){
  $('.nav a').click(function (e) {
    e.preventDefault();
    $(this).tab('show');
  });

  // store the currently selected tab in the hash value
  $("ul.nav-pills > li > a").on("shown.bs.tab", function (e) {
    var id = $(e.target).attr("href").substr(1);
    window.location.hash = id;
  });

  // on load of the page: switch to the currently selected tab
  var hash = window.location.hash;
  $('.nav a[href="' + hash + '"]').tab('show');
}


function makeUnitsMatchValue(event){

  if ( $(event.target).val() == 1 ){
    $('ul.dropdown-menu li').each(function(item){
      var a = $(this).find('a');
      a.text( a.text().slice(0,-1) );
    });
  }
  else{
    $('ul.dropdown-menu li').each(function(item){
      var a = $(this).find('a');
      // will break if we ever have a unit with an 's' in it
      if ( !(a.text().indexOf('s') > 0) ) {
        a.text( a.text() + 's' ); }
    });
  }

}


