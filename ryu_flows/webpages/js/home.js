/**
 * Contents and logic:
 * 1) Connection Manager
 *    - Waits for DOM ready and attaches submit handler to #connectForm.
 *    - Exposes window.disconnect() for the "Disconnect" button.
 *    - Validates src/dst and calls REST:
 *        - POST   /pair    {src,dst}  -> adds an allowed pair
 *        - DELETE /pair    {src,dst}  -> removes the pair
 *    - Prints the result with timestamp in the <pre id="output">.
 *
 * 2) Pairs View
 *    - Shows current pairs/"rules" from:
 *        - GET /pairs  -> { pairs:[ {src,dst, flows:[{dpid,match}]}, ... ] }
 *    - UI with "Refresh" button and Auto-refresh every 5s.
 *    - DOM requirements: #refreshPairs, #autorefresh, #pairsContainer.
 *
 * Note: this file is unique for Home; no other JS is needed.
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
      output.textContent = `[${getCurrentTime()}] Both source and destination are required.`;
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
        output.textContent = `[${time}] ${method === "POST" ? "Connection" : "Disconnection"} successful: ${text}`;
        output.style.color = "green";
      } else {
        output.textContent = `[${time}] ${method === "POST" ? "Connection" : "Disconnection"} failed: ${text}`;
        output.style.color = "red";
      }
    } catch (err) {
      output.textContent = `[${getCurrentTime()}] Error: ${err.message}`;
      output.style.color = "red";
    }
  }
});

/**
 * pairsView.js
 * - Shows allowed pairs from GET /pairs and, if present, installed flows.
 * - Refresh button + Auto-refresh (5s).
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
      container.innerHTML = `<p style="color:red">Error loading: ${escapeHtml(err.message)}</p>`;
    }
  }

  function renderPairs(data) {
    const pairs = (data && Array.isArray(data.pairs)) ? data.pairs : [];
    if (pairs.length === 0) {
      container.innerHTML = "<p>No rules configured.</p>";
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

  // load first time
  refresh();
});
