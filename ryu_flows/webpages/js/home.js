/**
 * Contenuti e logica:
 * 1) Connection Manager
 *    - Attende il DOM pronto e aggancia l’handler di submit al form #connectForm.
 *    - Espone window.disconnect() per il bottone "Disconnect".
 *    - Valida src/dst e chiama le REST:
 *        • POST   /pair    {src,dst}  → aggiunge una coppia consentita
 *        • DELETE /pair    {src,dst}  → rimuove la coppia
 *    - Stampa l’esito con timestamp nel <pre id="output">.
 *
 * 2) Pairs View
 *    - Mostra le coppie/“regole” correnti da:
 *        • GET /pairs  → { pairs:[ {src,dst, flows:[{dpid,match}]}, ... ] }
 *    - UI con pulsante “Refresh” e Auto-refresh ogni 5s.
 *    - Requisiti DOM: #refreshPairs, #autorefresh, #pairsContainer.
 *
 * Nota: questo file è unico per la Home; non servono altri JS.
*/

document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("connectForm");
  const output = document.getElementById("output");

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    handleConnection("POST");
  });

  window.disconnect = () => handleConnection("DELETE");

  function getCurrentTime() {
    const now = new Date();
    return now.toTimeString().split(' ')[0]; // Format HH:MM:SS
  }

  async function handleConnection(method) {
    const src = document.getElementById("src").value.trim();
    const dst = document.getElementById("dst").value.trim();

    if (!src || !dst) {
      output.textContent = `[${getCurrentTime()}] ❌ Both source and destination are required.`;
      output.style.color = "red";
      return;
    }

    const body = JSON.stringify({ src, dst });

    try {
      const res = await fetch("/pair", {
        method,
        headers: {
          "Content-Type": "application/json"
        },
        body
      });

      const text = await res.text();
      const time = getCurrentTime();
      if (res.ok) {
        output.textContent = `[${time}] ✅ ${method === "POST" ? "Connection" : "Disconnection"} successful: ${text}`;
        output.style.color = "green";
      } else {
        output.textContent = `[${time}] ❌ ${method === "POST" ? "Connection" : "Disconnection"} failed: ${text}`;
        output.style.color = "red";
      }
    } catch (err) {
      output.textContent = `[${getCurrentTime()}] ❌ Error: ${err.message}`;
      output.style.color = "red";
    }
  }
});

/**
 * pairsView.js
 * - Mostra le allowed pairs da GET /pairs e, se presenti, i flow installati.
 * - Bottone Refresh + Auto-refresh (5s).
 */
document.addEventListener("DOMContentLoaded", () => {
  const btn = document.getElementById("refreshPairs");
  const auto = document.getElementById("autorefresh");
  const container = document.getElementById("pairsContainer");
  let timer = null;

  btn?.addEventListener("click", refresh);
  auto?.addEventListener("change", (e) => {
    if (e.target.checked) {
      refresh();
      timer = setInterval(refresh, 5000);
    } else {
      clearInterval(timer);
      timer = null;
    }
  });

  async function refresh() {
    try {
      const res = await fetch("/pairs");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      renderPairs(data);
    } catch (err) {
      container.innerHTML = `<p style="color:red">Errore nel caricamento: ${escapeHtml(err.message)}</p>`;
    }
  }

  function renderPairs(data) {
    const pairs = (data && Array.isArray(data.pairs)) ? data.pairs : [];
    if (pairs.length === 0) {
      container.innerHTML = "<p>Nessuna regola configurata.</p>";
      return;
    }

    let html = `
      <table class="pairs-table" border="1" cellpadding="6" cellspacing="0">
        <thead>
          <tr>
            <th>#</th>
            <th>Src</th>
            <th>Dst</th>
          </tr>
        </thead>
        <tbody>
    `;

    pairs.forEach((p, i) => {
      // const flows = Array.isArray(p.flows) ? p.flows : [];
      // const flowsHtml = flows.length
      //   ? `<details><summary>${flows.length} flow${flows.length>1?'s':''}</summary>
      //        <ul style="margin:.4rem 0 0 .8rem">
      //          ${flows.map(f => `<li>dpid: ${escapeHtml(String(f.dpid ?? 'n/a'))} — match: <code>${escapeHtml(String(f.match ?? ''))}</code></li>`).join("")}
      //        </ul>
      //      </details>`
      //   : "—";
      html += `<tr>
          <td>${i + 1}</td>
          <td>${escapeHtml(p.src)}</td>
          <td>${escapeHtml(p.dst)}</td>
        </tr>`;
        // <td>${flowsHtml}</td>
    });

    html += "</tbody></table>";
    container.innerHTML = html;
  }

  function escapeHtml(str) {
    return String(str).replace(/[&<>"']/g, s => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[s]));
  }

  // carica una prima volta
  refresh();
});
