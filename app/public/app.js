'use strict';

// Browser client. Security notes:
// * The JWT lives only in this closure (memory). Not in localStorage, so it is
//   gone when the tab closes and cannot be read by other scripts/pages.
// * All server data is rendered with textContent, never innerHTML (no XSS).

(() => {
  let token = null;
  let user = null;
  let selectedId = null;

  const $ = (id) => document.getElementById(id);

  async function api(path, options = {}) {
    const headers = { Accept: 'application/json' };
    if (options.body !== undefined) headers['Content-Type'] = 'application/json';
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(path, {
      method: options.method || 'GET',
      headers,
      body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
      credentials: 'omit',
      cache: 'no-store',
    });
    if (res.status === 401 && token) {
      logout();
      throw new Error('Session expired. Please sign in again.');
    }
    const data = res.status === 204 ? {} : await res.json().catch(() => ({}));
    if (!res.ok) {
      const details = Array.isArray(data.details) ? ` (${data.details.map((d) => `${d.field}: ${d.message}`).join('; ')})` : '';
      throw new Error(`${data.error || `HTTP ${res.status}`}${details}`);
    }
    return data;
  }

  function show(el, text, isError) {
    el.textContent = text;
    el.classList.toggle('error', Boolean(isError));
    el.hidden = !text;
  }

  function setSignedIn(signedIn) {
    $('login-view').hidden = signedIn;
    $('app-view').hidden = !signedIn;
    $('session').hidden = !signedIn;
    if (signedIn) {
      $('whoami').textContent = user.displayName;
      $('role-badge').textContent = user.role;
      $('register-card').hidden = !['doctor', 'receptionist'].includes(user.role);
    }
  }

  function logout() {
    if (token) api('/api/auth/logout', { method: 'POST', body: {} }).catch(() => {});
    token = null;
    user = null;
    selectedId = null;
    $('patient-rows').replaceChildren();
    $('detail').replaceChildren();
    $('detail').hidden = true;
    $('detail-empty').hidden = false;
    $('clinical-form').hidden = true;
    setSignedIn(false);
  }

  async function loadPatients() {
    const { patients } = await api('/api/patients');
    const rows = patients.map((p) => {
      const tr = document.createElement('tr');
      tr.tabIndex = 0;
      tr.dataset.id = p.id;
      if (p.id === selectedId) tr.classList.add('selected');
      for (const value of [p.name, p.age, p.gender, p.bloodGroup]) {
        const td = document.createElement('td');
        td.textContent = String(value);
        tr.append(td);
      }
      const open = () => {
        loadPatient(p.id).catch((err) => show($('clinical-msg'), err.message, true));
      };
      tr.addEventListener('click', open);
      tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(); });
      return tr;
    });
    $('patient-rows').replaceChildren(...rows);
  }

  const LABELS = [
    ['firstName', 'First name'], ['lastName', 'Last name'], ['dateOfBirth', 'Date of birth'], ['age', 'Age'],
    ['gender', 'Gender'], ['bloodGroup', 'Blood group'], ['phone', 'Phone'], ['nationalId', 'National ID'],
    ['allergies', 'Allergies'], ['diagnosis', 'Diagnosis'], ['notes', 'Clinical notes'], ['updatedAt', 'Last updated'],
  ];

  async function loadPatient(id) {
    selectedId = id;
    const { patient } = await api(`/api/patients/${encodeURIComponent(id)}`);
    const items = [];
    for (const [key, label] of LABELS) {
      if (!(key in patient)) continue;
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      const v = patient[key];
      dd.textContent = Array.isArray(v) ? (v.join(', ') || 'None recorded') : (v ?? '—');
      items.push(dt, dd);
    }
    if (!('diagnosis' in patient)) {
      const dt = document.createElement('dt');
      dt.textContent = 'Clinical data';
      const dd = document.createElement('dd');
      dd.className = 'muted';
      dd.textContent = 'Hidden for your role (minimum necessary access)';
      items.push(dt, dd);
    }
    $('detail').replaceChildren(...items);
    $('detail').hidden = false;
    $('detail-empty').hidden = true;
    const canEdit = user.role === 'doctor';
    $('clinical-form').hidden = !canEdit;
    if (canEdit) {
      $('diagnosis').value = patient.diagnosis || '';
      $('notes').value = patient.notes || '';
      show($('clinical-msg'), '');
    }
    for (const tr of $('patient-rows').children) tr.classList.toggle('selected', tr.dataset.id === id);
  }

  function wrap(fn, msgEl) {
    return async (event) => {
      if (event) event.preventDefault();
      try {
        await fn(event);
      } catch (err) {
        if (msgEl) show(msgEl, err.message, true);
      }
    };
  }

  document.addEventListener('DOMContentLoaded', () => {
    $('login-form').addEventListener('submit', wrap(async () => {
      show($('login-error'), '');
      const data = await api('/api/auth/login', {
        method: 'POST',
        body: { username: $('username').value.trim(), password: $('password').value },
      });
      $('password').value = '';
      token = data.token;
      user = data.user;
      setSignedIn(true);
      await loadPatients();
    }, $('login-error')));

    $('logout').addEventListener('click', logout);
    $('refresh').addEventListener('click', wrap(loadPatients));

    $('clinical-form').addEventListener('submit', wrap(async () => {
      await api(`/api/patients/${encodeURIComponent(selectedId)}/clinical`, {
        method: 'PATCH',
        body: { diagnosis: $('diagnosis').value, notes: $('notes').value },
      });
      await loadPatient(selectedId);
      show($('clinical-msg'), 'Saved (re-encrypted and audit-logged).');
    }, $('clinical-msg')));

    $('register-form').addEventListener('submit', wrap(async () => {
      const form = $('register-form');
      const body = Object.fromEntries(new FormData(form).entries());
      body.allergies = body.allergies ? body.allergies.split(',').map((s) => s.trim()).filter(Boolean) : [];
      const { patient } = await api('/api/patients', { method: 'POST', body });
      form.reset();
      show($('register-msg'), `Registered ${patient.firstName} ${patient.lastName}.`);
      await loadPatients();
    }, $('register-msg')));
  });
})();
