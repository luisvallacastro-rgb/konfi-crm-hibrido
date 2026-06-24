let appState = null;
let activeTab = "agenda";
const content = document.querySelector("#mobileContent");
const summary = document.querySelector("#summary");
const dialog = document.querySelector("#mobileDialog");
const dialogContent = document.querySelector("#mobileDialogContent");
const newMobileProspect = document.querySelector("#newMobileProspect");

async function boot() {
  const response = await fetch("/api/bootstrap");
  appState = await response.json();
  renderSummary();
  renderContent();
}

async function apiRequest(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  appState = await response.json();
  renderSummary();
  renderContent();
}

function sellerItems() {
  return appState.agenda.filter((item) => item.ownerId === "u2");
}

function renderSummary() {
  const items = sellerItems();
  const total = items.reduce((sum, item) => sum + item.opportunity.estimatedAmount, 0);
  const hot = items.filter((item) => item.opportunity.temperature === "Caliente").length;
  summary.innerHTML = `
    <div><strong>${items.length}</strong><span>Visitas</span></div>
    <div><strong>${hot}</strong><span>Calientes</span></div>
    <div><strong>$${Math.round(total / 1000)}k</strong><span>Pipeline</span></div>
  `;
}

function agendaCard(item) {
  const opp = item.opportunity;
  return `
    <article class="mobile-card" data-open-opportunity="${opp.id}">
      <div class="card-head">
        <div>
          <h2>${opp.company}</h2>
          <p class="meta">${item.time} · ${item.type} · ${item.place}</p>
        </div>
        <span class="badge">${opp.priority}</span>
      </div>
      <div class="progress"><div style="width:${opp.stageId * 12.5}%"></div></div>
      <strong>Etapa ${opp.stageId}: ${opp.stage.name}</strong>
      <p class="meta">${item.status} · ${opp.nextAction}</p>
      <div class="actions">
        <button data-agenda-id="${item.id}" data-status="En visita">Check-in</button>
        <button data-agenda-id="${item.id}" data-status="Realizada">Realizada</button>
      </div>
    </article>
  `;
}

function renderContent() {
  if (activeTab === "agenda") {
    content.innerHTML = sellerItems().map(agendaCard).join("");
    bindAgendaActions();
    bindOpenOpportunity();
    return;
  }

  if (activeTab === "pipeline") {
    content.innerHTML = appState.opportunities
      .filter((opp) => opp.ownerId === "u2")
      .map(
        (opp) => `
          <article class="mobile-card" data-open-opportunity="${opp.id}">
            <div class="card-head">
              <h2>${opp.company}</h2>
              <span class="badge">${opp.temperature}</span>
            </div>
            <p class="meta">${opp.segment} · ${opp.location}</p>
            <div class="progress"><div style="width:${opp.stageId * 12.5}%"></div></div>
            <strong>${opp.estimatedAmountLabel}</strong>
            <p class="meta">Etapa ${opp.stageId}: ${opp.stage.name}</p>
          </article>
        `,
      )
      .join("");
    bindOpenOpportunity();
    return;
  }

  content.innerHTML = appState.forms
    .map(
      (form) => `
        <article class="mobile-card">
          <h2>${form.name}</h2>
          <p class="meta">Etapa ${form.stageId}</p>
          <p class="meta">${form.fields.slice(0, 5).join(" · ")}</p>
          <div class="actions">
            <button data-form-stage="${form.stageId}">Capturar</button>
            <button>Ver</button>
          </div>
        </article>
      `,
    )
    .join("");
  bindFormActions();
}

function bindAgendaActions() {
  content.querySelectorAll("[data-agenda-id]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      apiRequest(`/api/agenda/${button.dataset.agendaId}`, {
        method: "PATCH",
        body: JSON.stringify({ status: button.dataset.status }),
      });
    });
  });
}

function bindOpenOpportunity() {
  content.querySelectorAll("[data-open-opportunity]").forEach((card) => {
    card.addEventListener("click", () => {
      const opp = appState.opportunities.find((item) => item.id === card.dataset.openOpportunity);
      const agenda = appState.agenda.find((item) => item.opportunityId === opp.id);
      openOpportunityDialog(opp, agenda);
    });
  });
}

function bindFormActions() {
  content.querySelectorAll("[data-form-stage]").forEach((button) => {
    button.addEventListener("click", () => {
      const form = appState.forms.find((item) => String(item.stageId) === button.dataset.formStage);
      openFormDialog(form);
    });
  });
}

function openOpportunityDialog(opp, agenda) {
  dialogContent.innerHTML = `
    <h2>${opp.company}</h2>
    <p class="meta">${opp.contact} · ${opp.phone}</p>
    <div class="mini-grid">
      <div class="detail-row"><span>Etapa</span><strong>${opp.stageId}. ${opp.stage.name}</strong></div>
      <div class="detail-row"><span>Monto</span><strong>${opp.estimatedAmountLabel}</strong></div>
      <div class="detail-row"><span>Proxima accion</span><strong>${opp.nextAction}</strong></div>
      <label>
        Resultado
        <select id="visitResult">
          <option>Necesita cotizacion</option>
          <option>Objecion precio</option>
          <option>Enviar muestras</option>
          <option>Listo para cierre</option>
        </select>
      </label>
      <label>
        Nota
        <textarea id="visitNote" rows="3" placeholder="Compromiso o siguiente accion"></textarea>
      </label>
    </div>
    <div class="dialog-actions">
      <button id="closeDialog">Cerrar</button>
      <button id="completeVisit">Realizada</button>
    </div>
  `;
  dialog.showModal();
  document.querySelector("#closeDialog").addEventListener("click", () => dialog.close());
  document.querySelector("#completeVisit").addEventListener("click", () => {
    if (!agenda) return dialog.close();
    apiRequest(`/api/agenda/${agenda.id}`, {
      method: "PATCH",
      body: JSON.stringify({
        status: "Realizada",
        result: document.querySelector("#visitResult").value,
      }),
    });
    dialog.close();
  });
}

function openFormDialog(form) {
  dialogContent.innerHTML = `
    <h2>${form.name}</h2>
    <p class="meta">Etapa ${form.stageId}</p>
    <div class="mini-grid">
      ${form.fields.slice(0, 6).map((field) => `
        <label>${field}<input placeholder="${field}" /></label>
      `).join("")}
    </div>
    <div class="dialog-actions">
      <button id="closeDialog">Cancelar</button>
      <button id="saveForm">Guardar</button>
    </div>
  `;
  dialog.showModal();
  document.querySelector("#closeDialog").addEventListener("click", () => dialog.close());
  document.querySelector("#saveForm").addEventListener("click", () => dialog.close());
}

function openProspectDialog() {
  dialogContent.innerHTML = `
    <h2>Nuevo prospecto</h2>
    <p class="meta">Apertura rapida desde app movil</p>
    <div class="mini-grid">
      <label>Empresa<input id="newCompany" placeholder="Nombre de la empresa" /></label>
      <label>Contacto<input id="newContact" placeholder="Contacto principal" /></label>
      <label>Telefono<input id="newPhone" placeholder="+503 ..." /></label>
      <label>Monto estimado<input id="newAmount" type="number" placeholder="0" /></label>
    </div>
    <div class="dialog-actions">
      <button id="closeDialog">Cancelar</button>
      <button id="saveProspect">Abrir</button>
    </div>
  `;
  dialog.showModal();
  document.querySelector("#closeDialog").addEventListener("click", () => dialog.close());
  document.querySelector("#saveProspect").addEventListener("click", () => {
    apiRequest("/api/opportunities", {
      method: "POST",
      body: JSON.stringify({
        company: document.querySelector("#newCompany").value || "Nuevo prospecto",
        ownerId: "u2",
        contact: document.querySelector("#newContact").value,
        phone: document.querySelector("#newPhone").value,
        segment: "Prospeccion",
        location: "Por definir",
        stageId: 1,
        priority: "Media",
        temperature: "Tibio",
        estimatedAmount: Number(document.querySelector("#newAmount").value || 0),
        nextDate: "2026-06-11",
        nextAction: "Calificar prospecto y agendar contacto inicial",
        agendaDate: "2026-06-11",
        agendaTime: "15:00",
        agendaType: "Prospeccion",
        agendaPlace: "Llamada"
      }),
    });
    dialog.close();
  });
}

document.querySelectorAll(".tabs button").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tabs button").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    activeTab = button.dataset.tab;
    renderContent();
  });
});

newMobileProspect.addEventListener("click", openProspectDialog);

boot();
