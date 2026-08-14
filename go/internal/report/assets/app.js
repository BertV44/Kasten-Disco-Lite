(function(){
  var root = document.documentElement;
  var body = document.body;
  var content = document.querySelector(`.content`);
  var nav = document.getElementById(`nav`);
  if(!content || !nav){ return; }

  function el(tag, cls){ var e = document.createElement(tag); if(cls){ e.className = cls; } return e; }

  // ---------- 1. build sidebar nav from h2 headings ----------
  var heads = Array.prototype.slice.call(content.querySelectorAll(`h2`));
  var used = {};
  function slug(t){
    var s = (t||``).toLowerCase().replace(/[^a-z0-9]+/g, `-`).replace(/^-+/, ``).replace(/-+$/, ``);
    if(!s){ s = `section`; }
    if(used[s] !== undefined){ used[s] += 1; s = s + `-` + used[s]; } else { used[s] = 0; }
    return s;
  }
  var navLabel = el(`div`, `nav-label`); navLabel.textContent = `Sections`; nav.appendChild(navLabel);

  heads.forEach(function(h){
    var raw = (h.textContent || ``).replace(/v[0-9.]+ *$/, ``);
    var label = raw.replace(/^[^A-Za-z0-9]+/, ``).trim();
    if(!label){ label = `Section`; }
    var id = h.id || slug(label);
    h.id = id;
    // count severities between this h2 and the next
    var crit = 0, warn = 0, n = h.nextElementSibling;
    while(n && n.tagName !== `H2`){
      crit += n.querySelectorAll(`.badge.error, .badge.crit`).length;
      warn += n.querySelectorAll(`.badge.warn`).length;
      n = n.nextElementSibling;
    }
    var a = el(`a`); a.href = `#` + id;
    var lab = el(`span`, `label`); lab.textContent = label; a.appendChild(lab);
    if(crit > 0){ var pc = el(`span`, `pill crit`); pc.textContent = crit; a.appendChild(pc); }
    else if(warn > 0){ var pw = el(`span`, `pill warn`); pw.textContent = warn; a.appendChild(pw); }
    nav.appendChild(a);
  });

  // ---------- 2. scroll-spy ----------
  var links = Array.prototype.slice.call(nav.querySelectorAll(`a`));
  var byId = {};
  links.forEach(function(a){ byId[a.getAttribute(`href`).slice(1)] = a; });
  if(`IntersectionObserver` in window){
    var io = new IntersectionObserver(function(entries){
      entries.forEach(function(e){
        if(e.isIntersecting){
          links.forEach(function(l){ l.classList.remove(`active`); });
          if(byId[e.target.id]){ byId[e.target.id].classList.add(`active`); }
        }
      });
    }, { rootMargin: `-8% 0px -80% 0px` });
    heads.forEach(function(h){ io.observe(h); });
  }

  // ---------- 3. toggles ----------
  function press(btn, on){ btn.setAttribute(`aria-pressed`, on ? `true` : `false`); }
  var themeBtn = document.getElementById(`themeToggle`);
  if(themeBtn){ themeBtn.addEventListener(`click`, function(){
    var dark = root.getAttribute(`data-theme`) !== `light`;
    root.setAttribute(`data-theme`, dark ? `light` : `dark`);
    themeBtn.textContent = dark ? `Dark` : `Light`;
  }); }
  var densBtn = document.getElementById(`densityToggle`);
  if(densBtn){ densBtn.addEventListener(`click`, function(){ press(densBtn, body.classList.toggle(`dense`)); }); }
  var issuesBtn = document.getElementById(`issuesToggle`);
  if(issuesBtn){ issuesBtn.addEventListener(`click`, function(){ press(issuesBtn, body.classList.toggle(`only-issues`)); }); }

  // ---------- 4. mark rows that carry an issue ----------
  Array.prototype.slice.call(content.querySelectorAll(`table tbody tr`)).forEach(function(tr){
    if(tr.querySelector(`.badge.error, .badge.crit, .badge.warn`)){ tr.classList.add(`has-issue`); }
  });

  // ---------- 5. sortable + filterable tables ----------
  Array.prototype.slice.call(content.querySelectorAll(`table`)).forEach(function(table){
    var tbody = table.querySelector(`tbody`); if(!tbody){ return; }
    var ths = Array.prototype.slice.call(table.querySelectorAll(`thead th`));
    ths.forEach(function(th, idx){
      th.setAttribute(`data-sortable`, `1`);
      th.addEventListener(`click`, function(){
        var dir = th.getAttribute(`data-dir`) === `asc` ? `desc` : `asc`;
        ths.forEach(function(x){ x.removeAttribute(`data-dir`); });
        th.setAttribute(`data-dir`, dir);
        var rows = Array.prototype.slice.call(tbody.querySelectorAll(`tr`));
        rows.sort(function(a, b){
          var av = (a.children[idx] ? a.children[idx].textContent : ``).trim();
          var bv = (b.children[idx] ? b.children[idx].textContent : ``).trim();
          var an = parseFloat(av.replace(/[^0-9.-]/g, ``)), bn = parseFloat(bv.replace(/[^0-9.-]/g, ``));
          var num = !isNaN(an) && !isNaN(bn) && av !== `` && bv !== ``;
          var r = num ? (an - bn) : (av.toLowerCase() < bv.toLowerCase() ? -1 : av.toLowerCase() > bv.toLowerCase() ? 1 : 0);
          return r * (dir === `asc` ? 1 : -1);
        });
        rows.forEach(function(r){ tbody.appendChild(r); });
      });
    });
    if(tbody.querySelectorAll(`tr`).length >= 8){
      var tools = el(`div`, `tbl-tools`);
      var inp = el(`input`, `tbl-filter`); inp.type = `text`; inp.placeholder = `Filter ` + tbody.querySelectorAll(`tr`).length + ` rows...`;
      var hint = el(`span`, `tbl-hint`); hint.textContent = `click a header to sort`;
      tools.appendChild(inp); tools.appendChild(hint);
      table.parentNode.insertBefore(tools, table);
      inp.addEventListener(`input`, function(){
        var q = inp.value.toLowerCase();
        Array.prototype.slice.call(tbody.querySelectorAll(`tr`)).forEach(function(tr){
          tr.style.display = tr.textContent.toLowerCase().indexOf(q) > -1 ? `` : `none`;
        });
      });
    }
  });

  // ---------- 6. remediation worklist (findings only, no commands) ----------
  var bp = content.querySelector(`.bp-table`) || content.querySelector(`table`);
  var wl = document.getElementById(`worklist`);
  if(bp && wl){
    var items = [];
    Array.prototype.slice.call(bp.querySelectorAll(`tbody tr`)).forEach(function(tr){
      // Status column (index 2) tells pass/fail; a warn/error badge there = failing.
      var statusCell = tr.children[2];
      var sb = statusCell ? statusCell.querySelector(`.badge`) : null;
      var failing = sb && (sb.classList.contains(`error`) || sb.classList.contains(`crit`) || sb.classList.contains(`warn`));
      if(!failing){ return; }
      // Severity comes from the Severity column (index 1), NOT the badge color,
      // so the worklist stays consistent with the verdict counts. Skip Info/Optional.
      var sevText = (tr.children[1] ? tr.children[1].textContent : ``).trim().toLowerCase();
      var isCrit = sevText.indexOf(`critical`) > -1;
      var isWarn = sevText.indexOf(`warning`) > -1;
      if(!isCrit && !isWarn){ return; }
      var check = tr.children[0] ? tr.children[0].textContent.trim() : `Check`;
      var detail = tr.children[tr.children.length - 1] ? tr.children[tr.children.length - 1].textContent.trim() : ``;
      items.push({ crit: isCrit, check: check, detail: detail });
    });
    items.sort(function(a, b){ return (b.crit ? 1 : 0) - (a.crit ? 1 : 0); });
    if(items.length){
      var head = el(`div`, `wl-head`);
      head.textContent = `Remediation worklist - ` + items.length + ` item(s) need attention, ordered by severity`;
      wl.appendChild(head);
      items.forEach(function(it){
        var d = el(`details`, `wl-item`);
        var s = el(`summary`);
        var chev = el(`span`, `chev`); chev.textContent = `>`;
        var badge = el(`span`, `badge ` + (it.crit ? `crit` : `warn`)); badge.textContent = it.crit ? `Critical` : `Warning`;
        var title = el(`span`, `wl-title`); title.textContent = it.check;
        s.appendChild(chev); s.appendChild(badge); s.appendChild(title); d.appendChild(s);
        var b = el(`div`, `wl-body`); b.textContent = it.detail || `See the relevant section for details.`;
        d.appendChild(b); wl.appendChild(d);
      });
      wl.style.display = `block`;
    }
  }

  // ---------- 7. command palette (Ctrl-K) ----------
  var index = [];
  links.forEach(function(a){ index.push({ t: a.querySelector(`.label`).textContent, h: a.getAttribute(`href`), k: `section` }); });
  // add identifiers from first column of each table (namespaces, policies, profiles...)
  var seen = {};
  Array.prototype.slice.call(content.querySelectorAll(`table`)).forEach(function(table){
    var sec = table.closest(`section`);
    var target = null, p = table;
    while(p && p !== content){ if(p.previousElementSibling && p.previousElementSibling.tagName === `H2`){ target = p.previousElementSibling.id; break; } p = p.parentNode; }
    if(!target){ var pv = table.previousElementSibling; while(pv){ if(pv.tagName === `H2`){ target = pv.id; break; } pv = pv.previousElementSibling; } }
    Array.prototype.slice.call(table.querySelectorAll(`tbody tr`)).forEach(function(tr){
      var c = tr.children[0]; if(!c){ return; }
      var t = c.textContent.trim(); if(t.length < 2 || t.length > 60 || seen[t]){ return; }
      seen[t] = 1; index.push({ t: t, h: target ? (`#` + target) : `#`, k: `item` });
    });
  });

  var scrim = el(`div`, `palette-scrim`); scrim.id = `scrim`;
  var pal = el(`div`, `palette`); pal.id = `palette`;
  pal.innerHTML = `<input id="palInput" placeholder="Jump to a section or search..." autocomplete="off"><div class="results" id="palResults"></div>`;
  document.body.appendChild(scrim); document.body.appendChild(pal);
  var toast = el(`div`, `toast`); document.body.appendChild(toast);
  var pin = document.getElementById(`palInput`), pres = document.getElementById(`palResults`), sel = 0, items2 = [];
  function fuzzy(q, s){ q = q.toLowerCase(); s = s.toLowerCase(); var i = 0; for(var c = 0; c < s.length && i < q.length; c++){ if(s[c] === q[i]){ i++; } } return i === q.length; }
  function renderPal(){
    var q = pin.value.trim().toLowerCase();
    items2 = index.filter(function(x){ return !q || x.t.toLowerCase().indexOf(q) > -1 || fuzzy(q, x.t); });
    if(q){ items2.sort(function(a, b){ var ai = a.t.toLowerCase().indexOf(q), bi = b.t.toLowerCase().indexOf(q); return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi); }); }
    items2 = items2.slice(0, 50); sel = 0;
    if(!items2.length){ pres.innerHTML = `<div class="empty">No match.</div>`; return; }
    pres.innerHTML = items2.map(function(x, i){
      var t = document.createElement(`div`); t.textContent = x.t; var safe = t.innerHTML;
      return `<div class="res` + (i === 0 ? ` sel` : ``) + `" data-i="` + i + `"><span>` + safe + `</span><span class="rt">` + x.k + `</span></div>`;
    }).join(``);
  }
  function openPal(){ scrim.classList.add(`open`); pal.classList.add(`open`); pin.value = ``; renderPal(); pin.focus(); }
  function closePal(){ scrim.classList.remove(`open`); pal.classList.remove(`open`); }
  function goPal(x){ closePal(); var t = document.querySelector(x.h); if(t){ t.scrollIntoView({ behavior: `smooth` }); } }
  var openBtn = document.getElementById(`paletteOpen`);
  if(openBtn){ openBtn.addEventListener(`click`, openPal); }
  scrim.addEventListener(`click`, closePal);
  pin.addEventListener(`input`, renderPal);
  pres.addEventListener(`click`, function(e){ var r = e.target.closest(`.res`); if(r){ goPal(items2[+r.getAttribute(`data-i`)]); } });
  document.addEventListener(`keydown`, function(e){
    if((e.ctrlKey || e.metaKey) && (e.key === `k` || e.key === `K`)){ e.preventDefault(); openPal(); return; }
    if(e.key === `/` && document.activeElement && document.activeElement.tagName !== `INPUT`){ e.preventDefault(); openPal(); return; }
    if(!pal.classList.contains(`open`)){ return; }
    var res = pres.querySelectorAll(`.res`);
    if(e.key === `Escape`){ closePal(); }
    else if(e.key === `ArrowDown` || e.key === `ArrowUp`){
      e.preventDefault(); if(!res.length){ return; }
      if(res[sel]){ res[sel].classList.remove(`sel`); }
      sel = (sel + (e.key === `ArrowDown` ? 1 : -1) + res.length) % res.length;
      res[sel].classList.add(`sel`); res[sel].scrollIntoView({ block: `nearest` });
    } else if(e.key === `Enter`){ if(items2[sel]){ goPal(items2[sel]); } }
  });
})();
