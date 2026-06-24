let state = null;
let selectedOpportunityId = null;
let selectedCustomerOpportunityId = null;
let customerTab = "info";
let selectedSellerId = null;
let trackingStatusFilter = "Vigente";
let trackingStageFilter = "all";
let ownerFilter = "all";
let searchTerm = "";
let currentView = "sellers";
let agendaDateFilter = todayIso();
let agendaSellerFilter = "all";

const kpiGrid = document.querySelector("#kpiGrid");
const dashboardView = document.querySelector("#dashboardView");
const moduleView = document.querySelector("#moduleView");
const agendaList = document.querySelector("#agendaList");
const pipelineBoard = document.querySelector("#pipelineBoard");
const formsList = document.querySelector("#formsList");
const selectedCompany = document.querySelector("#selectedCompany");
const selectedDetail = document.querySelector("#selectedDetail");
const pipelineTotal = document.querySelector("#pipelineTotal");
const searchInput = document.querySelector("#searchInput");
const refreshButton = document.querySelector("#refreshButton");
const newOpportunityButton = document.querySelector("#newOpportunityButton");
const opportunityDialog = document.querySelector("#opportunityDialog");
const opportunityForm = document.querySelector("#opportunityForm");
const dialogTitle = document.querySelector("#dialogTitle");
const closeDialogButton = document.querySelector("#closeDialogButton");
const cancelDialogButton = document.querySelector("#cancelDialogButton");
const deleteOpportunityButton = document.querySelector("#deleteOpportunityButton");
const formMessage = document.querySelector("#formMessage");
const customerDialog = document.querySelector("#customerDialog");
const customerDialogTitle = document.querySelector("#customerDialogTitle");
const customerDialogBody = document.querySelector("#customerDialogBody");
const closeCustomerDialogButton = document.querySelector("#closeCustomerDialogButton");

const currency = new Intl.NumberFormat("es-SV", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function matchesSearch(opportunity) {
  if (!searchTerm) return true;
  const haystack = [
    opportunity.company,
    opportunity.product,
    opportunity.contact,
    opportunity.responsible,
    opportunity.segment,
    opportunity.location,
    opportunity.owner?.name,
    opportunity.stage?.name,
    opportunity.temperature,
    opportunity.status,
  ]
    .join(" ")
    .toLowerCase();
  return haystack.includes(searchTerm);
}

async function loadData() {
  const response = await fetch("/api/bootstrap");
  state = await response.json();
  const salesUsers = state.users.filter((user) => user.roleId === "sales_exec");
  if (!selectedSellerId && salesUsers.length) {
    selectedSellerId =
      salesUsers.find((user) => state.opportunities.some((item) => item.ownerId === user.id))?.id ||
      salesUsers[0].id;
  }
  if (!selectedOpportunityId && state.opportunities.length) {
    selectedOpportunityId = state.opportunities[0].id;
  }
  render();
}

async function apiRequest(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "No se pudo completar la accion");
  }
  state = payload;
  const salesUsers = state.users.filter((user) => user.roleId === "sales_exec");
  if (!salesUsers.some((user) => user.id === selectedSellerId)) {
    selectedSellerId = salesUsers[0]?.id || null;
  }
  if (!state.opportunities.some((item) => item.id === selectedOpportunityId)) {
    selectedOpportunityId = state.opportunities[0]?.id || null;
  }
  render();
  return payload;
}

function render() {
  renderKpis();
  renderAgenda();
  renderPipeline();
  renderSelected();
  renderForms();
  renderModule();
}

function renderKpis() {
  const kpis = [
    ["Seguimiento", state.kpis.totalPipelineLabel, "Monto estimado activo"],
    ["Oportunidades", state.kpis.totalProspects, "Prospectos y clientes en flujo"],
    ["Agenda", state.kpis.scheduledMeetings, "Acciones programadas"],
    ["En visita", state.kpis.inProgressVisits, "Ejecutivos en campo"],
    ["Realizadas", state.kpis.completedVisits, "Visitas completadas"],
    ["Cierre", `${state.kpis.closeRate}%`, "Etapa 6 o superior"],
    ["Calientes", state.kpis.hotOpportunities, "Prioridad comercial inmediata"],
    ["NPS", state.kpis.nps, "Satisfaccion postventa"],
    ["Reclamos", state.kpis.openClaims, "Casos abiertos"],
  ];

  kpiGrid.innerHTML = kpis
    .map(
      ([label, value, hint]) => `
        <article class="kpi-card">
          <span>${label}</span>
          <strong>${value}</strong>
          <span>${hint}</span>
        </article>
      `,
    )
    .join("");
}

function renderAgenda() {
  const items = state.agenda.filter((item) => {
    const ownerOk = ownerFilter === "all" || item.ownerId === ownerFilter;
    return ownerOk && matchesSearch(item.opportunity);
  });

  agendaList.innerHTML =
    items
      .map(
        (item) => `
          <article class="agenda-item" data-opportunity="${item.opportunityId}">
            <div class="timebox">${item.time}</div>
            <div>
              <h3>${item.type}: ${item.opportunity.company}</h3>
              <p class="meta">${item.date} Â· ${item.place}</p>
              <p class="small-meta">${item.owner.name} Â· ${item.opportunity.nextAction}</p>
            </div>
            <div class="agenda-actions">
              <span class="status">${item.status}</span>
              <button title="Marcar en visita" data-agenda-id="${item.id}" data-status="En visita">Iniciar</button>
              <button title="Marcar realizada" data-agenda-id="${item.id}" data-status="Realizada">OK</button>
            </div>
          </article>
        `,
      )
      .join("") || `<div class="empty-state">No hay agenda para este filtro.</div>`;

  document.querySelectorAll(".agenda-item").forEach((item) => {
    item.addEventListener("click", () => {
      selectedOpportunityId = item.dataset.opportunity;
      renderSelected();
    });
  });

  document.querySelectorAll("[data-agenda-id]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      updateAgendaStatus(button.dataset.agendaId, button.dataset.status);
    });
  });
}

function renderPipeline() {
  const filteredOpportunities = state.opportunities.filter(matchesSearch);
  const total = filteredOpportunities.reduce((sum, item) => sum + item.estimatedAmount, 0);
  pipelineTotal.textContent = currency.format(total);

  pipelineBoard.innerHTML = state.pipeline
    .map((stage) => {
      const opportunities = filteredOpportunities.filter((item) => item.stageId === stage.id);
      return `
        <section class="stage-column">
          <div class="stage-title">
            <h3>${stage.id}. ${stage.name}</h3>
            <span>${opportunities.length}</span>
          </div>
          ${
            opportunities
              .map(
                (opp) => `
                  <article class="opportunity-card" data-opportunity="${opp.id}">
                    <div class="card-row">
                      <strong>${opp.company}</strong>
                      <span class="priority ${opp.priority}">${opp.priority}</span>
                    </div>
                    <p class="small-meta">${opp.segment} Â· ${opp.location}</p>
                    <div class="card-row">
                      <span class="small-meta">${opp.owner.name}</span>
                      <strong>${opp.estimatedAmountLabel}</strong>
                    </div>
                  </article>
                `,
              )
              .join("") || `<div class="empty-state">Sin oportunidades</div>`
          }
        </section>
      `;
    })
    .join("");

  document.querySelectorAll(".opportunity-card").forEach((item) => {
    item.addEventListener("click", () => {
      selectedOpportunityId = item.dataset.opportunity;
      renderSelected();
    });
  });
}

function renderSelected() {
  const opp = state.opportunities.find((item) => item.id === selectedOpportunityId);
  if (!opp) {
    selectedCompany.textContent = "Selecciona una oportunidad";
    selectedDetail.innerHTML = `<div class="empty-state">No hay ficha seleccionada.</div>`;
    return;
  }

  selectedCompany.textContent = opp.company;
  const rows = [
    ["Etapa actual", `${opp.stageId}. ${opp.stage.name}`],
    ["Responsable", opp.owner.name],
    ["Contacto", `${opp.contact} Â· ${opp.phone}`],
    ["Segmento", `${opp.segment} Â· ${opp.location}`],
    ["Temperatura", `${opp.temperature} Â· prioridad ${opp.priority.toLowerCase()}`],
    ["Monto estimado", opp.estimatedAmountLabel],
    ["Proxima accion", `${opp.nextDate} Â· ${opp.nextAction}`],
    ["Nota", opp.lastNote],
  ];

  selectedDetail.innerHTML = rows
    .map(
      ([label, value]) => `
        <div class="detail-row">
          <span>${label}</span>
          <strong>${value}</strong>
        </div>
      `,
    )
    .join("") + `
      <div class="action-bar" style="justify-content:flex-start">
        <button class="secondary-button" data-action="edit-selected">Editar</button>
        <button class="danger-button" data-action="delete-selected">Eliminar</button>
      </div>
    `;

  selectedDetail.querySelector('[data-action="edit-selected"]').addEventListener("click", () => {
    openOpportunityDialog(opp);
  });
  selectedDetail.querySelector('[data-action="delete-selected"]').addEventListener("click", () => {
    deleteOpportunity(opp.id);
  });
}

function renderForms() {
  formsList.innerHTML = state.forms
    .map((form) => {
      const stage = state.stages.find((item) => item.id === form.stageId);
      return `
        <article class="form-card">
          <span>Etapa ${form.stageId}: ${stage.name}</span>
          <strong>${form.name}</strong>
          <div class="field-list">
            ${form.fields.map((field) => `<em>${field}</em>`).join("")}
          </div>
        </article>
      `;
    })
    .join("");
}

function renderModule() {
  if (currentView === "dashboard") {
    dashboardView.classList.remove("is-hidden");
    moduleView.classList.add("is-hidden");
    moduleView.classList.remove("is-tracking");
    return;
  }

  dashboardView.classList.add("is-hidden");
  moduleView.classList.remove("is-hidden");
  moduleView.classList.toggle("is-tracking", currentView === "pipeline");
  moduleView.classList.toggle("is-agenda", currentView === "agenda");

  const renderers = {
    agenda: renderAgendaModule,
    pipeline: renderPipelineModule,
    responses: renderResponsesModule,
    forms: renderFormsModule,
    sellers: renderSellersModule,
    kpis: renderKpisModule,
  };

  moduleView.innerHTML = renderers[currentView]();
  bindModuleClicks();
}

function renderAgendaModule() {
  const sellers = state.users
    .filter((user) => user.roleId === "sales_exec")
    .sort((a, b) => a.name.localeCompare(b.name));
  const slots = ["08:00", "09:00", "10:00", "11:00", "12:00", "13:00", "14:00", "15:00", "16:00", "17:00"];
  const dayItems = state.agenda.filter((item) => item.date === agendaDateFilter && matchesSearch(item.opportunity));
  const visibleSellers =
    agendaSellerFilter === "all" ? sellers : sellers.filter((seller) => seller.id === agendaSellerFilter);
  const occupiedCount = dayItems.length;
  const availableCount = Math.max(0, sellers.length * slots.length - occupiedCount);

  const sellerButtons = sellers
    .map((seller) => {
      const items = dayItems.filter((item) => item.ownerId === seller.id);
      const busySlots = new Set(items.map((item) => slotFor(item.time))).size;
      const freeSlots = Math.max(0, slots.length - busySlots);
      return `
        <button class="agenda-seller-card ${agendaSellerFilter === seller.id ? "is-active" : ""}" data-agenda-seller="${seller.id}">
          <strong>${seller.name}</strong>
          <span>${items.length} programadas Â· ${freeSlots} libres</span>
        </button>
      `;
    })
    .join("");

  const timeline = slots
    .map((slot) => {
      const slotItems = dayItems
        .filter((item) => slotFor(item.time) === slot)
        .filter((item) => agendaSellerFilter === "all" || item.ownerId === agendaSellerFilter)
        .sort((a, b) => String(a.time).localeCompare(String(b.time)));
      const busySellerIds = new Set(slotItems.map((item) => item.ownerId));
      const availableSellers = visibleSellers.filter((seller) => !busySellerIds.has(seller.id));
      const availabilityPreview = availableSellers
        .slice(0, 8)
        .map((seller) => `<span>${firstName(seller.name)}</span>`)
        .join("");
      const hiddenAvailable = Math.max(0, availableSellers.length - 8);

      const cards = slotItems
        .map(
          (item) => `
            <button class="agenda-visit-card" data-opportunity="${item.opportunityId}">
              <div>
                <strong>${item.opportunity.company}</strong>
                <span>${firstName(item.owner.name)}</span>
              </div>
              <p>${item.time} Â· ${item.type || "Gestion"}</p>
              <em>${item.place || "Por definir"}</em>
            </button>
          `,
        )
        .join("");

      return `
        <article class="agenda-hour-block">
          <div class="agenda-hour">
            <strong>${slot}</strong>
            <span>${endTime(slot)}</span>
          </div>
          <div class="agenda-hour-content">
            <div class="agenda-hour-topline">
              <strong>${slotItems.length ? `${slotItems.length} actividad${slotItems.length === 1 ? "" : "es"}` : "Sin actividades programadas"}</strong>
              <span>${availableSellers.length} vendedores disponibles</span>
            </div>
            <div class="agenda-hour-grid">
              ${cards || '<div class="agenda-open-slot">Horario libre para asignar visitas o llamadas.</div>'}
            </div>
            <div class="agenda-availability">
              <span>Disponibles</span>
              <div>${availabilityPreview}${hiddenAvailable ? `<strong>+${hiddenAvailable}</strong>` : ""}</div>
            </div>
          </div>
        </article>
      `;
    })
    .join("");

  return `
    <section class="agenda-hero panel">
      <div class="panel-header agenda-module-header">
        <div>
          <span class="eyebrow">Agenda integral</span>
          <h2>Disponibilidad por hora de todos los vendedores</h2>
          <p class="meta">Vista unificada para detectar espacios libres, visitas programadas y carga diaria por vendedor.</p>
        </div>
        <div class="action-bar">
          <button class="primary-button" data-agenda-today>Hoy</button>
          <label class="date-filter" title="Filtrar fecha exacta">
            <span>Calendario</span>
            <input type="date" value="${agendaDateFilter}" data-agenda-date />
          </label>
        </div>
      </div>
      <div class="agenda-day-summary">
        <div><span>Fecha</span><strong>${displayDate(agendaDateFilter)}</strong></div>
        <div><span>Programadas</span><strong>${occupiedCount}</strong></div>
        <div><span>Disponibles</span><strong>${availableCount}</strong></div>
        <div><span>Vendedores</span><strong>${sellers.length}</strong></div>
      </div>
    </section>
    <section class="agenda-command-layout">
      <aside class="panel agenda-seller-rail">
        <span class="eyebrow">Equipo</span>
        <button class="agenda-seller-card ${agendaSellerFilter === "all" ? "is-active" : ""}" data-agenda-seller="all">
          <strong>Todos los vendedores</strong>
          <span>${occupiedCount} programadas Â· ${availableCount} espacios libres</span>
        </button>
        <div class="agenda-seller-list">${sellerButtons}</div>
      </aside>
      <section class="panel agenda-timeline-panel">
        <div class="agenda-timeline-head">
          <div>
            <span class="eyebrow">Bitacora por hora</span>
            <h2>${agendaSellerFilter === "all" ? "Agenda integral del equipo" : visibleSellers[0]?.name || "Agenda del vendedor"}</h2>
          </div>
          <span class="total-pill">${displayDate(agendaDateFilter)}</span>
        </div>
        <div class="agenda-timeline">${timeline}</div>
      </section>
    </section>
  `;
}

function renderResponsesModule() {
  const responses = (state.gestiones || [])
    .filter((item) => matchesSearch(item.opportunity || {}))
    .sort((a, b) => String(b.updatedAt || b.createdAt || "").localeCompare(String(a.updatedAt || a.createdAt || "")));
  const responseAgendaIds = new Set(responses.map((item) => item.agendaId).filter(Boolean));
  const pendingCommitments = (state.agenda || [])
    .filter((item) => matchesSearch(item.opportunity || {}))
    .filter((item) => !responseAgendaIds.has(item.id))
    .map((item) => ({
      ...item,
      source: "Agenda CRM",
      result: "Sin respuesta",
      note: item.opportunity?.nextAction || "Pendiente de respuesta desde la app.",
      locationLabel: item.place,
    }));
  const mailboxItems = [...responses, ...pendingCommitments].sort((a, b) =>
    `${b.date || ""} ${b.time || ""}`.localeCompare(`${a.date || ""} ${a.time || ""}`),
  );
  const fulfilledResponses = responses.length;
  const pendingResponses = pendingCommitments.length;
  const today = todayIso();
  const todayResponses = mailboxItems.filter((item) => item.date === today).length;

  const rows =
    mailboxItems
      .map((item) => {
        const fulfilled = item.source !== "Agenda CRM";
        const sender = item.owner?.name || "Vendedor";
        const client = item.company || item.opportunity?.company || "Sin cliente";
        const type = item.type || "Gestion";
        const result = item.result || "Sin respuesta";
        const note = item.note || "Sin nota de seguimiento.";
        const location = item.locationLabel || item.place || item.opportunity?.location || "Ubicacion no reportada";
        return `
          <article class="mail-row ${fulfilled ? "is-done" : "is-pending"}" data-opportunity="${item.opportunityId}">
            <span class="mail-check"></span>
            <strong class="mail-from">${sender}</strong>
            <span class="mail-client">${client}</span>
            <span class="mail-type">${type}</span>
            <span class="mail-result">${result}</span>
            <span class="mail-note-line">${note}</span>
            <span class="mail-location">${location}</span>
            <time class="mail-date">${item.date || "Sin fecha"} ${item.time || ""}</time>
            <span class="response-state ${fulfilled ? "is-done" : "is-pending"}">${fulfilled ? "Cumplido" : "Pendiente"}</span>
            ${item.id?.startsWith("ges-") ? `<button class="mail-delete" title="Eliminar respuesta" data-gestion-delete="${item.id}">x</button>` : `<span class="mail-delete-placeholder"></span>`}
          </article>
        `;
      })
      .join("") || '<div class="empty-state">Aun no hay respuestas de visitas o compromisos.</div>';

  return `
    <section class="panel responses-hero">
      <div class="panel-header">
        <div>
          <span class="eyebrow">Respuestas</span>
          <h2>Bandeja de compromisos y respuestas</h2>
          <p class="meta">Filas tipo correo: vendedor, cliente, compromiso, respuesta, nota, ubicacion, fecha y estado.</p>
        </div>
      </div>
      <div class="agenda-day-summary">
        <div><span>Pendientes</span><strong>${pendingResponses}</strong></div>
        <div><span>Cumplidos</span><strong>${fulfilledResponses}</strong></div>
        <div><span>Hoy</span><strong>${todayResponses}</strong></div>
        <div><span>Vendedores</span><strong>${new Set(mailboxItems.map((item) => item.ownerId)).size}</strong></div>
      </div>
    </section>
    <section class="responses-layout">
      <div class="mail-inbox">
        <div class="mail-row mail-row-head">
          <span></span>
          <strong>De</strong>
          <strong>Cliente</strong>
          <strong>Compromiso</strong>
          <strong>Respuesta</strong>
          <strong>Nota</strong>
          <strong>Ubicacion</strong>
          <strong>Fecha</strong>
          <strong>Estado</strong>
          <span></span>
        </div>
        ${rows}
      </div>
    </section>
  `;
}

function renderPipelineModule() {
  const sellers = state.users
    .filter((user) => user.roleId === "sales_exec")
    .sort((a, b) => {
      const aCount = state.opportunities.filter((item) => item.ownerId === a.id).length;
      const bCount = state.opportunities.filter((item) => item.ownerId === b.id).length;
      return bCount - aCount || a.name.localeCompare(b.name);
    });
  const selectedSeller = sellers.find((user) => user.id === selectedSellerId) || sellers[0];
  const sellerOpportunities = selectedSeller
    ? state.opportunities.filter((item) => item.ownerId === selectedSeller.id)
    : [];
  const activeOpportunities = sellerOpportunities.filter((item) => item.status === "Vigente");
  const wonOpportunities = sellerOpportunities.filter((item) => item.status === "Ganada");
  const lostOpportunities = sellerOpportunities.filter((item) => item.status === "Perdida");
  const activeValue = activeOpportunities.reduce((sum, item) => sum + item.estimatedAmount, 0);
  const wonValue = wonOpportunities.reduce((sum, item) => sum + item.estimatedAmount, 0);
  const conversionBase = wonOpportunities.length + lostOpportunities.length;
  const conversion = conversionBase ? Math.round((wonOpportunities.length / conversionBase) * 100) : 0;

  const statusOptions = [
    ["Vigente", "Vigentes"],
    ["Ganada", "Ganadas"],
    ["Perdida", "Perdidas"],
    ["all", "Todas"],
  ];
  const statusFiltered =
    trackingStatusFilter === "all"
      ? sellerOpportunities
      : sellerOpportunities.filter((item) => item.status === trackingStatusFilter);

  const stagesWithCounts = state.stages.map((stage) => {
    const items = statusFiltered.filter((item) => item.stageId === stage.id);
    return {
      ...stage,
      count: items.length,
      amount: items.reduce((sum, item) => sum + item.estimatedAmount, 0),
    };
  });

  const stageFiltered =
    trackingStageFilter === "all"
      ? statusFiltered
      : statusFiltered.filter((item) => item.stageId === Number(trackingStageFilter));

  const visibleOpportunities = [...stageFiltered]
    .sort((a, b) => {
      const dateCompare = String(a.deadline || a.nextDate || "").localeCompare(String(b.deadline || b.nextDate || ""));
      return dateCompare || b.estimatedAmount - a.estimatedAmount;
    });

  const sellerButtons = sellers
    .map((seller) => {
      const active = state.opportunities.filter((item) => item.ownerId === seller.id && item.status === "Vigente");
      const activeTotal = active.reduce((sum, item) => sum + item.estimatedAmount, 0);
      return `
        <button class="seller-chip ${seller.id === selectedSeller?.id ? "is-active" : ""}" data-seller-id="${seller.id}">
          <strong>${seller.name}</strong>
          <span>${active.length} vigentes - ${currency.format(activeTotal)}</span>
        </button>
      `;
    })
    .join("");

  const stageButtons = [
    `<button class="stage-filter ${trackingStageFilter === "all" ? "is-active" : ""}" data-tracking-stage="all">Todas</button>`,
    ...stagesWithCounts
      .filter((stage) => stage.count > 0)
      .map(
        (stage) => `
          <button class="stage-filter ${String(stage.id) === String(trackingStageFilter) ? "is-active" : ""}" data-tracking-stage="${stage.id}">
            <span class="stage-tab">Etapa ${stage.id}</span>
            <em>${stage.name}</em>
            <strong>${stage.count} ops</strong>
          </button>
        `,
      ),
  ].join("");

  const opportunityCards =
    visibleOpportunities
      .map(
        (opp) => `
          <article class="tracking-card" data-opportunity="${opp.id}">
            <div>
              <span class="small-meta">${opp.originalStage || `${opp.stageId}. ${opp.stage?.name || "Etapa"}`} - ${opp.status}</span>
              <h3>${opp.company}</h3>
              <p>${opp.product || "Producto pendiente"}</p>
            </div>
            <div class="tracking-card-footer">
              <strong>${opp.estimatedAmountLabel}</strong>
              <span>${opp.closePercent || 0}% cierre</span>
            </div>
          </article>
        `,
      )
      .join("") || '<div class="empty-state">No hay oportunidades para este filtro.</div>';

  return `
    <section class="tracking-hero panel">
      <div class="panel-header tracking-header">
        <div>
          <span class="eyebrow">Seguimiento individual</span>
          <h2>${selectedSeller?.name || "Selecciona vendedor"}</h2>
          <p class="meta">Vista enfocada por vendedor, estatus y etapa. Sin ruido, solo cartera accionable.</p>
        </div>
        <button class="primary-button" data-action="new-opportunity">Abrir oportunidad</button>
      </div>
      <div class="tracking-metrics">
        <div><span>Vigentes</span><strong>${activeOpportunities.length}</strong></div>
        <div><span>Valor vigente</span><strong>${currency.format(activeValue)}</strong></div>
        <div><span>Ganadas</span><strong>${currency.format(wonValue)}</strong></div>
        <div><span>Conversion</span><strong>${conversion}%</strong></div>
      </div>
    </section>
    <section class="tracking-layout">
      <aside class="tracking-sidebar panel">
        <span class="eyebrow">Vendedores</span>
        <div class="seller-chip-list">${sellerButtons}</div>
      </aside>
      <section class="tracking-main">
        <section class="panel tracking-controls">
          <div>
            <span class="eyebrow">Estatus</span>
            <div class="filter-chips">
              ${statusOptions
                .map(
                  ([value, label]) =>
                    `<button class="${trackingStatusFilter === value ? "is-active" : ""}" data-tracking-status="${value}">${label}</button>`,
                )
                .join("")}
            </div>
          </div>
          <div>
            <span class="eyebrow">Etapa</span>
            <div class="stage-filter-list">${stageButtons}</div>
          </div>
        </section>
        <section class="tracking-grid">${opportunityCards}</section>
      </section>
    </section>
  `;
}
function renderFormsModule() {
  const forms = state.forms
    .map((form) => {
      const stage = state.stages.find((item) => item.id === form.stageId);
      return `
        <article class="panel">
          <span class="eyebrow">Etapa ${form.stageId}: ${stage.name}</span>
          <h2>${form.name}</h2>
          <div class="field-list" style="margin-top:14px">
            ${form.fields.map((field) => `<em>${field}</em>`).join("")}
          </div>
          <div class="action-bar" style="margin-top:16px; justify-content:flex-start">
            <button class="secondary-button">Ver registros</button>
            <button class="primary-button">Capturar</button>
          </div>
        </article>
      `;
    })
    .join("");

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <span class="eyebrow">Modulo formularios</span>
          <h2>Anexos del proceso convertidos en capturas digitales</h2>
        </div>
      </div>
    </section>
    <section class="module-grid two">${forms}</section>
  `;
}

function renderSellersModule() {
  const sellers = state.users.filter((user) => user.roleId === "sales_exec");
  sellers.sort((a, b) => {
    const aCount = state.opportunities.filter((item) => item.ownerId === a.id).length;
    const bCount = state.opportunities.filter((item) => item.ownerId === b.id).length;
    return bCount - aCount || a.name.localeCompare(b.name);
  });
  const rows = sellers
    .map((user) => {
      const activeOpportunities = state.opportunities.filter((item) => {
        const status = String(item.status || "Vigente").toLowerCase();
        return item.ownerId === user.id && !["ganada", "perdida", "cancelada"].includes(status);
      });
      const activePipeline = activeOpportunities
        .reduce((sum, item) => sum + item.estimatedAmount, 0);

      return `
        <tr class="seller-row" data-seller-id="${user.id}">
          <td>
            <strong>${user.name}</strong><br>
            <span class="small-meta">${user.initials || "SV"} - ${user.status || "Activo"}</span>
          </td>
          <td>${activeOpportunities.length}</td>
          <td>${currency.format(activePipeline)}</td>
          <td><span class="link-pill">Abrir seguimiento</span></td>
        </tr>
      `;
    })
    .join("");

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <span class="eyebrow">Modulo vendedores</span>
        </div>
        <span class="total-pill">${sellers.length} activos</span>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>Vendedor</th>
              <th>Oportunidades vigentes</th>
              <th>Venta probable vigente</th>
              <th>Acceso</th>
            </tr>
          </thead>
          <tbody>${rows || '<tr><td colspan="4"><div class="empty-state">No hay vendedores registrados.</div></td></tr>'}</tbody>
        </table>
      </div>
    </section>
  `;
}

function todayIso() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function displayDate(value) {
  if (!value) return "";
  const [year, month, day] = value.split("-");
  return `${day}/${month}/${year}`;
}

function slotFor(time = "09:00") {
  const hour = Number(String(time).split(":")[0]) || 9;
  return `${String(hour).padStart(2, "0")}:00`;
}

function endTime(slot) {
  const [hourText, minuteText] = String(slot).split(":");
  const date = new Date(2026, 0, 1, Number(hourText) || 9, Number(minuteText) || 0);
  date.setMinutes(date.getMinutes() + 45);
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function firstName(name = "") {
  return String(name).trim().split(/\s+/)[0] || "Vendedor";
}

function renderKpisModule() {
  const stageRows = state.pipeline
    .map((stage) => {
      const conversion = Math.round((stage.count / state.opportunities.length) * 100);
      return `
        <div class="metric-row">
          <strong>${stage.name}</strong>
          <div class="progress-track">
            <div class="progress-fill" style="width:${Math.max(4, conversion)}%"></div>
          </div>
          <span>${conversion}%</span>
        </div>
      `;
    })
    .join("");

  return `
    <section class="module-grid two">
      <article class="panel">
        <span class="eyebrow">KPI comercial</span>
        <h2>Conversion por etapa</h2>
        <div style="margin-top:14px">${stageRows}</div>
      </article>
      <article class="panel">
        <span class="eyebrow">Postventa</span>
        <h2>Salud de clientes</h2>
        <div class="kpi-grid" style="grid-template-columns:repeat(2,1fr); margin-top:14px">
          <div class="kpi-card"><span>NPS</span><strong>${state.kpis.nps}</strong><span>Satisfaccion</span></div>
          <div class="kpi-card"><span>Reclamos</span><strong>${state.kpis.openClaims}</strong><span>Abiertos</span></div>
          <div class="kpi-card"><span>En visita</span><strong>${state.kpis.inProgressVisits}</strong><span>Campo</span></div>
          <div class="kpi-card"><span>Realizadas</span><strong>${state.kpis.completedVisits}</strong><span>Cumplimiento</span></div>
        </div>
      </article>
    </section>
  `;
}

function bindModuleClicks() {
  moduleView.querySelectorAll("[data-opportunity]").forEach((item) => {
    item.addEventListener("click", () => {
      selectedOpportunityId = item.dataset.opportunity;
      const opportunity = state.opportunities.find((opp) => opp.id === selectedOpportunityId);
      if (opportunity) openCustomerDialog(opportunity.id);
    });
  });

  moduleView.querySelectorAll("[data-seller-id]").forEach((item) => {
    item.addEventListener("click", () => {
      selectedSellerId = item.dataset.sellerId;
      trackingStageFilter = "all";
      if (currentView === "sellers") {
        currentView = "pipeline";
        document.querySelectorAll(".nav button").forEach((button) => {
          button.classList.toggle("active", button.dataset.view === "pipeline");
        });
        render();
        return;
      }
      renderModule();
    });
  });

  moduleView.querySelectorAll("[data-tracking-status]").forEach((item) => {
    item.addEventListener("click", () => {
      trackingStatusFilter = item.dataset.trackingStatus;
      trackingStageFilter = "all";
      renderModule();
    });
  });

  moduleView.querySelectorAll("[data-tracking-stage]").forEach((item) => {
    item.addEventListener("click", () => {
      trackingStageFilter = item.dataset.trackingStage;
      renderModule();
    });
  });

  moduleView.querySelectorAll("[data-agenda-today]").forEach((button) => {
    button.addEventListener("click", () => {
      agendaDateFilter = todayIso();
      renderModule();
    });
  });

  moduleView.querySelectorAll("[data-agenda-date]").forEach((input) => {
    input.addEventListener("change", () => {
      agendaDateFilter = input.value || todayIso();
      renderModule();
    });
  });

  moduleView.querySelectorAll("[data-agenda-seller]").forEach((button) => {
    button.addEventListener("click", () => {
      agendaSellerFilter = button.dataset.agendaSeller;
      renderModule();
    });
  });

  moduleView.querySelectorAll('[data-action="new-opportunity"]').forEach((button) => {
    button.addEventListener("click", () => openOpportunityDialog());
  });

  moduleView.querySelectorAll("[data-agenda-id]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      updateAgendaStatus(button.dataset.agendaId, button.dataset.status);
    });
  });

  moduleView.querySelectorAll("[data-gestion-delete]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      deleteGestion(button.dataset.gestionDelete);
    });
  });
}

async function updateAgendaStatus(agendaId, status) {
  await apiRequest(`/api/agenda/${agendaId}`, {
    method: "PATCH",
    body: JSON.stringify({ status }),
  });
}

function populateDialogOptions() {
  const ownerSelect = opportunityForm.elements.ownerId;
  const stageSelect = opportunityForm.elements.stageId;
  const salesUsers = state.users.filter((user) => user.roleId === "sales_exec");

  ownerSelect.innerHTML = salesUsers
    .map((user) => `<option value="${user.id}">${user.name}</option>`)
    .join("");

  stageSelect.innerHTML = state.stages
    .map((stage) => `<option value="${stage.id}">${stage.id}. ${stage.name}</option>`)
    .join("");
}

function findAgendaForOpportunity(opportunityId) {
  return state.agenda.find((item) => item.opportunityId === opportunityId);
}

function openOpportunityDialog(opportunity = null) {
  populateDialogOptions();
  opportunityForm.reset();
  formMessage.textContent = "";
  dialogTitle.textContent = opportunity ? "Editar oportunidad" : "Nueva oportunidad";
  deleteOpportunityButton.classList.toggle("is-hidden", !opportunity);

  const today = new Date().toISOString().slice(0, 10);
  opportunityForm.elements.id.value = opportunity?.id || "";
  opportunityForm.elements.company.value = opportunity?.company || "";
  opportunityForm.elements.ownerId.value =
    opportunity?.ownerId || state.users.find((user) => user.roleId === "sales_exec")?.id || "";
  opportunityForm.elements.contact.value = opportunity?.contact || "";
  opportunityForm.elements.phone.value = opportunity?.phone || "";
  opportunityForm.elements.segment.value = opportunity?.segment || "";
  opportunityForm.elements.location.value = opportunity?.location || "";
  opportunityForm.elements.stageId.value = opportunity?.stageId || "1";
  opportunityForm.elements.priority.value = opportunity?.priority || "Media";
  opportunityForm.elements.temperature.value = opportunity?.temperature || "Tibio";
  opportunityForm.elements.estimatedAmount.value = opportunity?.estimatedAmount || "";
  opportunityForm.elements.nextDate.value = opportunity?.nextDate || today;
  opportunityForm.elements.nextAction.value = opportunity?.nextAction || "Primer seguimiento";
  opportunityForm.elements.lastNote.value = opportunity?.lastNote || "";

  const agenda = opportunity ? findAgendaForOpportunity(opportunity.id) : null;
  opportunityForm.elements.agendaDate.value = agenda?.date || opportunity?.nextDate || today;
  opportunityForm.elements.agendaTime.value = agenda?.time || "";
  opportunityForm.elements.agendaType.value = agenda?.type || "";
  opportunityForm.elements.agendaPlace.value = agenda?.place || "";

  opportunityDialog.showModal();
}

function closeOpportunityDialog() {
  opportunityDialog.close();
}

function formPayload() {
  const data = Object.fromEntries(new FormData(opportunityForm).entries());
  return {
    company: data.company,
    ownerId: data.ownerId,
    contact: data.contact,
    phone: data.phone,
    segment: data.segment,
    location: data.location,
    stageId: Number(data.stageId),
    priority: data.priority,
    temperature: data.temperature,
    estimatedAmount: Number(data.estimatedAmount || 0),
    nextDate: data.nextDate,
    nextAction: data.nextAction,
    lastNote: data.lastNote,
    agendaDate: data.agendaDate,
    agendaTime: data.agendaTime,
    agendaType: data.agendaType,
    agendaPlace: data.agendaPlace,
  };
}

async function saveOpportunity() {
  const id = opportunityForm.elements.id.value;
  const payload = formPayload();
  formMessage.textContent = "Guardando...";

  await apiRequest(id ? `/api/opportunities/${id}` : "/api/opportunities", {
    method: id ? "PUT" : "POST",
    body: JSON.stringify(payload),
  });

  if (!id) {
    selectedOpportunityId = state.opportunities[state.opportunities.length - 1]?.id || selectedOpportunityId;
    render();
  }
  closeOpportunityDialog();
}

async function deleteOpportunity(id = opportunityForm.elements.id.value) {
  if (!id) return;
  const opportunity = state.opportunities.find((item) => item.id === id);
  const ok = window.confirm(`Eliminar oportunidad de ${opportunity?.company || "este cliente"}?`);
  if (!ok) return;

  formMessage.textContent = "Eliminando...";
  await apiRequest(`/api/opportunities/${id}`, { method: "DELETE" });
  closeOpportunityDialog();
}

function sameCustomer(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
}

function fieldValue(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function selectedOption(value, option) {
  return String(value || "") === option ? "selected" : "";
}

function currentOption(value, options) {
  const current = String(value || "").trim();
  if (!current || options.includes(current)) return "";
  return `<option selected>${fieldValue(current)}</option>`;
}

function customerOpportunities(opportunity) {
  return state.opportunities
    .filter((item) => sameCustomer(item.company, opportunity.company))
    .sort((a, b) => String(b.startDate || b.nextDate || "").localeCompare(String(a.startDate || a.nextDate || "")));
}

function customerGestiones(opportunity) {
  return (state.gestiones || [])
    .filter((item) => item.opportunityId === opportunity.id || sameCustomer(item.company, opportunity.company))
    .sort((a, b) => `${b.date || ""} ${b.time || ""}`.localeCompare(`${a.date || ""} ${a.time || ""}`));
}

function customerAgenda(opportunity) {
  return state.agenda
    .filter((item) => item.opportunityId === opportunity.id || sameCustomer(item.opportunity?.company, opportunity.company))
    .sort((a, b) => `${b.date || ""} ${b.time || ""}`.localeCompare(`${a.date || ""} ${a.time || ""}`));
}

function renderCustomerInfo(opportunity, history, gestiones) {
  const won = history.filter((item) => item.status === "Ganada");
  const active = history.filter((item) => item.status === "Vigente");
  const totalWon = won.reduce((sum, item) => sum + item.estimatedAmount, 0);
  const totalActive = active.reduce((sum, item) => sum + item.estimatedAmount, 0);
  const customer = opportunity.customer || {};

  return `
    <section class="customer-workspace">
      <aside class="customer-side-summary">
        <span class="eyebrow">Resumen comercial</span>
        <div><span>Vendedor</span><strong>${opportunity.owner?.name || "Sin asignar"}</strong></div>
        <div><span>Vigentes</span><strong>${active.length}</strong></div>
        <div><span>Venta probable</span><strong>${currency.format(totalActive)}</strong></div>
        <div><span>Pedidos ganados</span><strong>${currency.format(totalWon)}</strong></div>
        <div><span>Etapa actual</span><strong>${opportunity.originalStage || `${opportunity.stageId}. ${opportunity.stage?.name || "Etapa"}`}</strong></div>
        <div><span>Ultima gestion</span><strong>${gestiones[0]?.type || "Sin gestiones"}</strong></div>
      </aside>

      <form id="customerInfoForm" class="customer-info-form">
        <input type="hidden" name="id" value="${fieldValue(customer.id || opportunity.customerId)}" />

        <section class="customer-form-section">
          <div class="section-heading">
            <span class="eyebrow">Informacion legal</span>
            <strong>Datos fiscales y razon social</strong>
          </div>
          <div class="customer-form-grid">
            <label>
              Razon social
              <input name="legalName" value="${fieldValue(customer.legalName || opportunity.company)}" placeholder="Razon social registrada" />
            </label>
            <label>
              Nombre comercial
              <input name="commercialName" value="${fieldValue(customer.commercialName || opportunity.company)}" placeholder="Nombre visible para ventas" />
            </label>
            <label>
              NIT
              <input name="nit" value="${fieldValue(customer.nit)}" placeholder="0000-000000-000-0" />
            </label>
            <label>
              NRC
              <input name="nrc" value="${fieldValue(customer.nrc)}" placeholder="000000-0" />
            </label>
            <label>
              Giro
              <select name="businessLine">
                ${currentOption(customer.businessLine, ["Salud", "Educacion", "Industria", "Gobierno", "Comercio", "Servicios", "Por definir"])}
                <option ${selectedOption(customer.businessLine, "Salud")}>Salud</option>
                <option ${selectedOption(customer.businessLine, "Educacion")}>Educacion</option>
                <option ${selectedOption(customer.businessLine, "Industria")}>Industria</option>
                <option ${selectedOption(customer.businessLine, "Gobierno")}>Gobierno</option>
                <option ${selectedOption(customer.businessLine, "Comercio")}>Comercio</option>
                <option ${selectedOption(customer.businessLine, "Servicios")}>Servicios</option>
                <option ${selectedOption(customer.businessLine, "Por definir")}>Por definir</option>
              </select>
            </label>
            <label>
              Tipo de cliente
              <select name="customerType">
                ${currentOption(customer.customerType, ["Empresa privada", "Institucion publica", "ONG", "Distribuidor", "Persona natural"])}
                <option ${selectedOption(customer.customerType, "Empresa privada")}>Empresa privada</option>
                <option ${selectedOption(customer.customerType, "Institucion publica")}>Institucion publica</option>
                <option ${selectedOption(customer.customerType, "ONG")}>ONG</option>
                <option ${selectedOption(customer.customerType, "Distribuidor")}>Distribuidor</option>
                <option ${selectedOption(customer.customerType, "Persona natural")}>Persona natural</option>
              </select>
            </label>
            <label>
              Categoria fiscal
              <select name="fiscalCategory">
                ${currentOption(customer.fiscalCategory, ["Contribuyente", "Gran contribuyente", "No contribuyente", "Exento"])}
                <option ${selectedOption(customer.fiscalCategory, "Contribuyente")}>Contribuyente</option>
                <option ${selectedOption(customer.fiscalCategory, "Gran contribuyente")}>Gran contribuyente</option>
                <option ${selectedOption(customer.fiscalCategory, "No contribuyente")}>No contribuyente</option>
                <option ${selectedOption(customer.fiscalCategory, "Exento")}>Exento</option>
              </select>
            </label>
          </div>
        </section>

        <section class="customer-form-section">
          <div class="section-heading">
            <span class="eyebrow">Contacto y ubicacion</span>
            <strong>Datos operativos del cliente</strong>
          </div>
          <div class="customer-form-grid">
            <label>
              Telefono
              <input name="phone" value="${fieldValue(customer.phone || opportunity.phone)}" placeholder="+503 0000-0000" />
            </label>
            <label>
              Correo
              <input name="email" type="email" value="${fieldValue(customer.email)}" placeholder="compras@cliente.com" />
            </label>
            <label>
              Encargado
              <input name="manager" value="${fieldValue(customer.manager || opportunity.responsible || opportunity.contact)}" placeholder="Persona responsable" />
            </label>
            <label>
              Departamento
              <select name="department">
                ${currentOption(customer.department, ["San Salvador", "La Libertad", "Santa Ana", "San Miguel", "Sonsonate", "Usulutan", "Otro"])}
                <option ${selectedOption(customer.department, "San Salvador")}>San Salvador</option>
                <option ${selectedOption(customer.department, "La Libertad")}>La Libertad</option>
                <option ${selectedOption(customer.department, "Santa Ana")}>Santa Ana</option>
                <option ${selectedOption(customer.department, "San Miguel")}>San Miguel</option>
                <option ${selectedOption(customer.department, "Sonsonate")}>Sonsonate</option>
                <option ${selectedOption(customer.department, "Usulutan")}>Usulutan</option>
                <option ${selectedOption(customer.department, "Otro")}>Otro</option>
              </select>
            </label>
            <label>
              Municipio
              <input name="municipality" value="${fieldValue(customer.municipality)}" placeholder="Municipio" />
            </label>
            <label class="span-2">
              Direccion
              <input name="address" value="${fieldValue(customer.address || opportunity.location)}" placeholder="Direccion completa" />
            </label>
          </div>
        </section>

        <section class="customer-form-section">
          <div class="section-heading">
            <span class="eyebrow">Condiciones comerciales</span>
            <strong>Parametros para venta y credito</strong>
          </div>
          <div class="customer-form-grid">
            <label>
              Condicion de pago
              <select name="paymentCondition">
                ${currentOption(customer.paymentCondition, ["Contado", "Credito", "Contra entrega", "Licitacion"])}
                <option ${selectedOption(customer.paymentCondition, "Contado")}>Contado</option>
                <option ${selectedOption(customer.paymentCondition, "Credito")}>Credito</option>
                <option ${selectedOption(customer.paymentCondition, "Contra entrega")}>Contra entrega</option>
                <option ${selectedOption(customer.paymentCondition, "Licitacion")}>Licitacion</option>
              </select>
            </label>
            <label>
              Limite de credito
              <input name="creditLimit" type="number" min="0" step="100" value="${fieldValue(customer.creditLimit || 0)}" />
            </label>
            <label>
              Producto actual
              <input value="${fieldValue(opportunity.product || "Pendiente")}" disabled />
            </label>
            <label>
              % cierre oportunidad
              <input value="${fieldValue(`${opportunity.closePercent || 0}%`)}" disabled />
            </label>
            <label class="span-4">
              Observaciones del cliente
              <textarea name="notes" rows="3" placeholder="Notas fiscales, comerciales o de atencion">${fieldValue(customer.notes || opportunity.comment || opportunity.lastNote)}</textarea>
            </label>
          </div>
        </section>

        <div class="modal-actions customer-save-row">
          <span id="customerInfoMessage" class="form-message"></span>
          <button type="submit" class="primary-button">Guardar ficha del cliente</button>
        </div>
      </form>
    </section>
  `;
}

function renderCustomerHistory(history) {
  const rows = history
    .map(
      (item) => `
        <article class="history-item">
          <div>
            <span class="small-meta">${item.startDate || item.nextDate || "Sin fecha"} - ${item.status}</span>
            <strong>${item.product || "Producto pendiente"}</strong>
            <p>${item.originalStage || `${item.stageId}. ${item.stage?.name || "Etapa"}`} Â· ${item.closePercent || 0}% cierre</p>
          </div>
          <strong>${item.estimatedAmountLabel}</strong>
        </article>
      `,
    )
    .join("");

  return `
    <section class="history-list">
      ${rows || '<div class="empty-state">Este cliente todavia no tiene historial registrado.</div>'}
    </section>
  `;
}

function renderGestionForm(opportunity) {
  const today = new Date().toISOString().slice(0, 10);
  return `
    <form id="gestionForm" class="gestion-form">
      <input type="hidden" name="opportunityId" value="${opportunity.id}" />
      <div class="form-grid compact-grid">
        <label>
          Tipo
          <select name="type">
            <option>Visita</option>
            <option>Llamada</option>
            <option>WhatsApp</option>
            <option>Correo</option>
            <option>Nota</option>
          </select>
        </label>
        <label>
          Fecha
          <input name="date" type="date" value="${today}" />
        </label>
        <label>
          Hora
          <input name="time" type="time" value="09:00" />
        </label>
        <label>
          Estado
          <select name="status">
            <option>Programada</option>
            <option>Realizada</option>
            <option>Pendiente</option>
            <option>Reprogramada</option>
            <option>Cancelada</option>
          </select>
        </label>
      </div>
      <label class="full-label">
        Detalle / resultado
        <textarea name="note" rows="3" placeholder="Ej. llamada con compras, se agenda visita, pendiente cotizacion..."></textarea>
      </label>
      <div class="modal-actions">
        <span id="gestionMessage" class="form-message"></span>
        <button type="submit" class="primary-button">Guardar gestion</button>
      </div>
    </form>
  `;
}

function renderCustomerActions(opportunity, gestiones, agenda) {
  const agendaItems = agenda
    .map(
      (item) => `
        <article class="gestion-item agenda-origin">
          <div>
            <span class="small-meta">Agenda CRM Â· ${item.date} ${item.time || ""}</span>
            <strong>${item.type || "Seguimiento"} Â· ${item.status}</strong>
            <p>${item.place || item.opportunity?.nextAction || "Sin detalle"}</p>
          </div>
        </article>
      `,
    )
    .join("");
  const gestionItems = gestiones
    .map(
      (item) => `
        <article class="gestion-item">
          <div>
            <span class="small-meta">${item.date} ${item.time || ""} Â· ${item.status}</span>
            <strong>${item.type}</strong>
            <p>${item.note || item.result || "Sin detalle"}</p>
          </div>
          <div class="gestion-actions">
            ${
              item.status === "Realizada"
                ? '<span class="done-pill">Realizada</span>'
                : `<button type="button" class="secondary-button compact-action" data-complete-gestion="${item.id}">Marcar realizada</button>`
            }
            <button type="button" class="danger-button compact-danger" data-delete-gestion="${item.id}">Eliminar</button>
          </div>
        </article>
      `,
    )
    .join("");

  return `
    ${renderGestionForm(opportunity)}
    <section class="gestion-timeline">
      <span class="eyebrow">Linea de gestiones</span>
      ${gestionItems || agendaItems ? `${gestionItems}${agendaItems}` : '<div class="empty-state">Aun no hay gestiones para este cliente.</div>'}
    </section>
  `;
}

function renderCustomerDialog() {
  const opportunity = state.opportunities.find((item) => item.id === selectedCustomerOpportunityId);
  if (!opportunity) return;

  const history = customerOpportunities(opportunity);
  const gestiones = customerGestiones(opportunity);
  const agenda = customerAgenda(opportunity);

  customerDialogTitle.textContent = opportunity.company;
  customerDialog.querySelectorAll("[data-customer-tab]").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.customerTab === customerTab);
  });

  if (customerTab === "history") {
    customerDialogBody.innerHTML = renderCustomerHistory(history);
    return;
  }
  if (customerTab === "actions") {
    customerDialogBody.innerHTML = renderCustomerActions(opportunity, gestiones, agenda);
    return;
  }
  customerDialogBody.innerHTML = renderCustomerInfo(opportunity, history, gestiones);
}

function openCustomerDialog(opportunityId) {
  selectedCustomerOpportunityId = opportunityId;
  customerTab = "info";
  renderCustomerDialog();
  customerDialog.showModal();
}

function closeCustomerDialog() {
  customerDialog.close();
}

async function saveCustomerInfo() {
  const opportunity = state.opportunities.find((item) => item.id === selectedCustomerOpportunityId);
  const form = customerDialog.querySelector("#customerInfoForm");
  const message = customerDialog.querySelector("#customerInfoMessage");
  if (!opportunity || !form) return;

  const data = Object.fromEntries(new FormData(form).entries());
  if (message) message.textContent = "Guardando ficha...";

  await apiRequest(`/api/customers/${data.id || opportunity.customerId}`, {
    method: "PATCH",
    body: JSON.stringify(data),
  });
  customerTab = "info";
  renderCustomerDialog();
}

async function saveGestion() {
  const opportunity = state.opportunities.find((item) => item.id === selectedCustomerOpportunityId);
  if (!opportunity) return;
  const form = customerDialog.querySelector("#gestionForm");
  const message = customerDialog.querySelector("#gestionMessage");
  const data = Object.fromEntries(new FormData(form).entries());
  if (message) message.textContent = "Guardando...";

  await apiRequest("/api/gestiones", {
    method: "POST",
    body: JSON.stringify({
      ...data,
      company: opportunity.company,
      ownerId: opportunity.ownerId,
    }),
  });
  customerTab = "actions";
  renderCustomerDialog();
}

async function deleteGestion(id) {
  await apiRequest(`/api/gestiones/${id}`, { method: "DELETE" });
  customerTab = "actions";
  renderCustomerDialog();
}

async function completeGestion(id) {
  await apiRequest(`/api/gestiones/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ status: "Realizada", result: "Gestion realizada desde ficha de cliente" }),
  });
  customerTab = "actions";
  renderCustomerDialog();
}

document.querySelectorAll(".segmented button").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".segmented button").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    ownerFilter = button.dataset.owner;
    renderAgenda();
  });
});

document.querySelectorAll(".nav button").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".nav button").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    currentView = button.dataset.view;
    renderModule();
  });
});

newOpportunityButton.addEventListener("click", () => openOpportunityDialog());
closeDialogButton.addEventListener("click", closeOpportunityDialog);
cancelDialogButton.addEventListener("click", closeOpportunityDialog);
deleteOpportunityButton.addEventListener("click", () => deleteOpportunity());
closeCustomerDialogButton.addEventListener("click", closeCustomerDialog);

opportunityForm.addEventListener("submit", (event) => {
  event.preventDefault();
  saveOpportunity().catch((error) => {
    formMessage.textContent = error.message;
  });
});

customerDialog.addEventListener("click", (event) => {
  const tabButton = event.target.closest("[data-customer-tab]");
  if (tabButton) {
    customerTab = tabButton.dataset.customerTab;
    renderCustomerDialog();
    return;
  }

  const deleteButton = event.target.closest("[data-delete-gestion]");
  if (deleteButton) {
    deleteGestion(deleteButton.dataset.deleteGestion).catch((error) => {
      const message = customerDialog.querySelector("#gestionMessage");
      if (message) message.textContent = error.message;
    });
    return;
  }

  const completeButton = event.target.closest("[data-complete-gestion]");
  if (completeButton) {
    completeGestion(completeButton.dataset.completeGestion).catch((error) => {
      const message = customerDialog.querySelector("#gestionMessage");
      if (message) message.textContent = error.message;
    });
  }
});

customerDialog.addEventListener("submit", (event) => {
  event.preventDefault();
  if (event.target.id === "customerInfoForm") {
    saveCustomerInfo().catch((error) => {
      const message = customerDialog.querySelector("#customerInfoMessage");
      if (message) message.textContent = error.message;
    });
    return;
  }
  if (event.target.id !== "gestionForm") return;
  saveGestion().catch((error) => {
    const message = customerDialog.querySelector("#gestionMessage");
    if (message) message.textContent = error.message;
  });
});

searchInput.addEventListener("input", (event) => {
  searchTerm = event.target.value.trim().toLowerCase();
  renderAgenda();
  renderPipeline();
});

refreshButton.addEventListener("click", loadData);

loadData().catch((error) => {
  document.body.innerHTML = `<main class="app-shell"><section class="panel"><h1>No se pudo cargar el CRM</h1><p>${error.message}</p></section></main>`;
});
