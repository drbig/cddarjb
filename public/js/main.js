'use strict';

var backend = 'http://localhost:8112/backend';
var VERSION = '0.9.1';

var templates = {
  search: Handlebars.compile($('#t-search').html()),
  list: Handlebars.compile($('#t-list').html()),
  show: Handlebars.compile($('#t-show').html()),
  status: Handlebars.compile($('#t-status').html()),
  error: Handlebars.compile($('#t-error').html()),
  help: Handlebars.compile($('#t-help').html()),
};

function template(templateName, data) {
  return templates[templateName](data);
}

var $outlet = $('#outlet');
var $query = $('#query');

var current;
var counter = 1;
var panelsById = {};

function nextUid() {
  return counter++;
}

function scrollTo($target) {
  $('html, body').animate({
    scrollTop: $target.offset().top - 64
  }, 1000);
}

function closeAll() {
  $outlet.empty();
}

function mkUrl() {
  return backend + '/' + Array.prototype.slice.call(arguments).join('/');
}

function closePanel(uid) {
  panelsById[uid].remove();
}

function addPanel(templateName, data) {
  var uid = data.uid = nextUid();
  $outlet.append(template(templateName, data));
  var $panel = $outlet.find('#panel' + uid);
  panelsById[uid] = $panel;
  $panel.find('.table-sortable').tablesorter({
    sortList: [[0, 0]]
  });
  scrollTo($panel);
  current = uid;
  return $panel;
}

function selectPanel(offset) {
  if ($outlet.children().length == 0) {
    return;
  }
  do {
    var panel = current + offset;
    if (panel > (counter - 1)) {
      panel = 0;
    }
    if (panel < 0) {
      panel = counter - 1;
    }
    current = panel;
  } while ($('#panel' + current).length == 0);
  $('html, body').animate({
    scrollTop: $('#panel' + current).offset().top - 64
  }, 1000);
};

function request(url, templateName, extraData) {
  $.ajax({
    url: url,
    success: function(resp, stat, xhr) {
      var tplData;
      if (resp.success) {
        tplData = {
          data: resp.data
        };
      } else {
        templateName = 'error';
        tplData =  {
          msg: resp.error,
          url: url,
          src: 'Backend'
        };
      }
      tplData = $.extend(tplData, extraData);
      addPanel(templateName, tplData);
    },
    error: function(xhr, stat, err) {
      var msg = ['All I know:', xhr.statusText, stat, err].join(' ');
      msg += ' - yeah, most likely the backend is unreachable.';
      addPanel('error', {
        uid: counter,
        msg: msg,
        url: url,
        src: 'Frontend'
      });
    }
  });
}

function search() {
  var query = $query.val();
  if (query === '') {
    return;
  }
  var url = mkUrl('search', encodeURI(query));
  request(url, 'search', {
    query: query,
    sortable: true
  });
}

function show(type, id) {
  request(mkUrl('blobs', type, id), 'show', {
    type: type,
    id: id
  });
};

function list(type, id) {
  request(mkUrl('list', type, id), 'list', {
    type: type,
    id: id
  });
};

function status() {
  request(mkUrl('status'), 'status', {
    version: VERSION
  });
}

function help() {
  addPanel('help', {});
}

$('#btn-search').on('click', search);
$('#btn-status').on('click', status);
$('#btn-help').on('click', help);
$('#btn-close-all').on('click', closeAll);

$query.keyup(function(ev) {
  if (ev.which == 13) { // enter
    search();
  }
});

$('body').keyup(function(ev) {
  if (document.activeElement.id == 'query') {
    return;
  }
  if (ev.ctrlKey) {
    return;
  }
  switch (ev.which) {
    case 37: // left arrow
      selectPanel(-1);
      break;
    case 39: // right arrow
      selectPanel(1);
      break;
    case 67: // 'c'
      closePanel(current);
      break;
  }
});

$(function() {
  if (window.location.hash.length > 4) {
    var args = window.location.hash.slice(1).split(':');
    switch (args[0]) {
      case 'blob':
        if (args.length == 2) {
          var sargs = args[1].split('/');
          if (sargs.length == 2) {
            show(sargs[0], sargs[1]);
          };
        }
        break;
      case 'search':
        if (args.length == 2) {
          $query.val(args[1]);
          search();
        }
        break;
      case 'list':
        if (args.length == 2) {
          var sargs = args[1].split('/');
          if (sargs.length == 2) {
            list(sargs[0], sargs[1]);
          };
        }
        break;
      case 'status':
        status();
        break;
      case 'help':
        help();
        break;
    }
  }
});
