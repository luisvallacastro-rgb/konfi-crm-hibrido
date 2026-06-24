const http = require("http");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");

const PORT = Number(process.env.PORT || 4180);
const HOST = process.env.HOST || "0.0.0.0";
const rootDir = path.resolve(__dirname, "..");
const webDir = path.join(rootDir, "web-crm");
const seedPath = path.join(__dirname, "data", "seed.json");
const dataPath = process.env.DATA_PATH
  ? path.resolve(process.env.DATA_PATH)
  : seedPath;

function ensureDataFile() {
  if (fs.existsSync(dataPath)) {
    return;
  }
  fs.mkdirSync(path.dirname(dataPath), { recursive: true });
  fs.copyFileSync(seedPath, dataPath);
}

function readData() {
  ensureDataFile();
  const data = JSON.parse(fs.readFileSync(dataPath, "utf8"));
  data.gestiones = Array.isArray(data.gestiones) ? data.gestiones : [];
  data.customers = Array.isArray(data.customers) ? data.customers : [];
  return data;
}

function writeData(data) {
  fs.mkdirSync(path.dirname(dataPath), { recursive: true });
  fs.writeFileSync(dataPath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1_000_000) {
        req.destroy();
        reject(new Error("Payload too large"));
      }
    });
    req.on("end", () => {
      if (!body) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(body));
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res, payload, status = 200) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(body);
}

function sendFile(res, filePath, baseDir = webDir) {
  if (!filePath.startsWith(baseDir)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.readFile(filePath, (err, content) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const types = {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "application/javascript; charset=utf-8",
      ".json": "application/json; charset=utf-8",
      ".svg": "image/svg+xml",
    };

    res.writeHead(200, {
      "Content-Type": types[ext] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    res.end(content);
  });
}

function toCurrency(value) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(value);
}

function customerKey(value) {
  return requireText(value, "cliente")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

function normalizeCustomer(input, existing = {}) {
  const legalName = requireText(input.legalName, existing.legalName || input.company || input.commercialName);
  const commercialName = requireText(input.commercialName, existing.commercialName || input.company || legalName);
  return {
    ...existing,
    id: requireText(existing.id || input.id, customerKey(commercialName || legalName)),
    legalName,
    commercialName,
    phone: requireText(input.phone, existing.phone),
    email: requireText(input.email, existing.email),
    manager: requireText(input.manager, existing.manager || input.responsible || input.contact),
    businessLine: requireText(input.businessLine, existing.businessLine || input.segment || "Por definir"),
    nit: requireText(input.nit, existing.nit),
    nrc: requireText(input.nrc, existing.nrc),
    address: requireText(input.address, existing.address || input.location),
    department: requireText(input.department, existing.department || "San Salvador"),
    municipality: requireText(input.municipality, existing.municipality),
    customerType: requireText(input.customerType, existing.customerType || "Empresa privada"),
    fiscalCategory: requireText(input.fiscalCategory, existing.fiscalCategory || "Contribuyente"),
    paymentCondition: requireText(input.paymentCondition, existing.paymentCondition || "Credito"),
    creditLimit: Number(input.creditLimit ?? existing.creditLimit ?? 0),
    notes: requireText(input.notes, existing.notes),
    updatedAt: new Date().toISOString(),
  };
}

function buildViewModel(data) {
  const usersById = Object.fromEntries(data.users.map((user) => [user.id, user]));
  const stagesById = Object.fromEntries(data.stages.map((stage) => [stage.id, stage]));
  const customersById = Object.fromEntries(data.customers.map((customer) => [customer.id, customer]));

  const opportunities = data.opportunities.map((opportunity) => ({
    ...opportunity,
    customerId: opportunity.customerId || customerKey(opportunity.company),
    customer:
      customersById[opportunity.customerId || customerKey(opportunity.company)] ||
      normalizeCustomer({
        id: customerKey(opportunity.company),
        company: opportunity.company,
        phone: opportunity.phone,
        responsible: opportunity.responsible,
        contact: opportunity.contact,
        segment: opportunity.segment,
        location: opportunity.location,
      }),
    owner: usersById[opportunity.ownerId],
    stage: stagesById[opportunity.stageId],
    estimatedAmountLabel: toCurrency(opportunity.estimatedAmount),
  }));

  const agenda = data.agenda
    .map((item) => {
      const opportunity = opportunities.find((opp) => opp.id === item.opportunityId);
      if (!opportunity) return null;
      return {
        ...item,
        opportunity,
        owner: usersById[item.ownerId],
      };
    })
    .filter(Boolean)
    .sort((a, b) => `${a.date} ${a.time}`.localeCompare(`${b.date} ${b.time}`));

  const gestiones = data.gestiones
    .map((item) => {
      const opportunity = opportunities.find((opp) => opp.id === item.opportunityId);
      return {
        ...item,
        opportunity,
        owner: usersById[item.ownerId],
      };
    })
    .sort((a, b) => `${b.date || ""} ${b.time || ""}`.localeCompare(`${a.date || ""} ${a.time || ""}`));

  const totalPipeline = opportunities.reduce((sum, item) => sum + item.estimatedAmount, 0);
  const closed = opportunities.filter((item) => item.stageId >= 6).length;
  const hot = opportunities.filter((item) => item.temperature === "Caliente").length;
  const scheduled = agenda.filter((item) => item.status === "Programada").length;
  const inProgress = agenda.filter((item) => item.status === "En visita").length;
  const completed = agenda.filter((item) => item.status === "Realizada").length;

  const pipeline = data.stages.map((stage) => {
    const stageOpportunities = opportunities.filter((opp) => opp.stageId === stage.id);
    return {
      ...stage,
      count: stageOpportunities.length,
      amount: stageOpportunities.reduce((sum, item) => sum + item.estimatedAmount, 0),
      amountLabel: toCurrency(stageOpportunities.reduce((sum, item) => sum + item.estimatedAmount, 0)),
      opportunities: stageOpportunities,
    };
  });

  return {
    company: data.company,
    generatedAt: new Date().toISOString(),
    roles: data.roles,
    users: data.users,
    customers: data.customers,
    stages: data.stages,
    forms: data.forms,
    opportunities,
    agenda,
    gestiones,
    pipeline,
    kpis: {
      totalProspects: opportunities.length,
      totalPipeline,
      totalPipelineLabel: toCurrency(totalPipeline),
      hotOpportunities: hot,
      scheduledMeetings: scheduled,
      inProgressVisits: inProgress,
      completedVisits: completed,
      closeRate: opportunities.length ? Math.round((closed / opportunities.length) * 100) : 0,
      nps: data.postSales.nps,
      openClaims: data.postSales.openClaims,
    },
  };
}

function requireText(value, fallback = "") {
  return String(value || fallback).trim();
}

function initialsFromName(name) {
  const initials = requireText(name, "KV")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0].toUpperCase())
    .join("");
  return initials || "KV";
}

function normalizeUser(input, existing = {}) {
  const firstName = requireText(input.firstName, existing.firstName);
  const lastName = requireText(input.lastName, existing.lastName);
  const fullName = requireText(`${firstName} ${lastName}`.trim(), existing.name);
  const name = requireText(input.name, fullName);
  const email = requireText(input.email, existing.email);
  return {
    ...existing,
    name,
    firstName,
    lastName,
    dui: requireText(input.dui, existing.dui),
    address: requireText(input.address, existing.address),
    roleId: requireText(input.roleId, existing.roleId || "sales_exec"),
    initials: requireText(input.initials, existing.initials || initialsFromName(name)),
    phone: requireText(input.phone, existing.phone),
    email,
    username: requireText(input.username, existing.username || email),
    password: requireText(input.password, existing.password || "konfi123"),
    territory: requireText(input.territory, existing.territory || "Por definir"),
    status: requireText(input.status, existing.status || "Activo"),
  };
}

function normalizeIdentity(value) {
  return requireText(value).toLowerCase();
}

function duplicateUser(data, input, currentId = "") {
  const email = normalizeIdentity(input.email);
  const username = normalizeIdentity(input.username || input.email);
  const dui = requireText(input.dui);

  return data.users.find((user) => {
    if (user.id === currentId) return false;
    const existingEmail = normalizeIdentity(user.email);
    const existingUsername = normalizeIdentity(user.username || user.email);
    const existingDui = requireText(user.dui);
    return (
      (email && existingEmail === email) ||
      (username && existingUsername === username) ||
      (dui && existingDui === dui)
    );
  });
}

function normalizeOpportunity(input, existing = {}) {
  const stageId = Number(input.stageId ?? existing.stageId ?? 1);
  const estimatedAmount = Number(input.estimatedAmount ?? existing.estimatedAmount ?? 0);
  const closePercent = Number(input.closePercent ?? existing.closePercent ?? 0);

  return {
    ...existing,
    startDate: requireText(input.startDate, existing.startDate || new Date().toISOString().slice(0, 10)),
    deadline: requireText(input.deadline, existing.deadline),
    company: requireText(input.company, existing.company),
    product: requireText(input.product, existing.product),
    contact: requireText(input.contact, existing.contact || input.responsible),
    phone: requireText(input.phone, existing.phone),
    segment: requireText(input.segment, existing.segment),
    location: requireText(input.location, existing.location),
    stageId: Number.isFinite(stageId) ? Math.min(8, Math.max(1, stageId)) : 1,
    priority: requireText(input.priority, existing.priority || "Media"),
    temperature: requireText(input.temperature, existing.temperature || "Tibio"),
    estimatedAmount: Number.isFinite(estimatedAmount) ? Math.max(0, estimatedAmount) : 0,
    closePercent: Number.isFinite(closePercent) ? Math.min(100, Math.max(0, closePercent)) : 0,
    strategy: requireText(input.strategy, existing.strategy),
    status: requireText(input.status, existing.status || "Vigente"),
    responsible: requireText(input.responsible, existing.responsible || input.contact),
    ownerId: requireText(input.ownerId, existing.ownerId || "u2"),
    nextAction: requireText(input.nextAction, existing.nextAction || "Primer seguimiento"),
    nextDate: requireText(input.nextDate, existing.nextDate || input.deadline || new Date().toISOString().slice(0, 10)),
    lastNote: requireText(input.lastNote, existing.lastNote || input.comment),
    comment: requireText(input.comment, existing.comment || input.lastNote),
  };
}

function upsertAgendaForOpportunity(data, opportunity, input) {
  const hasAgenda = input.agendaDate || input.agendaTime || input.agendaType || input.agendaPlace;
  const existing = data.agenda.find((item) => item.opportunityId === opportunity.id);

  if (!hasAgenda && !existing) return;

  const agendaItem = {
    id: existing?.id || `ag-${Date.now()}`,
    date: requireText(input.agendaDate, existing?.date || opportunity.nextDate),
    time: requireText(input.agendaTime, existing?.time || "09:00"),
    type: requireText(input.agendaType, existing?.type || "Seguimiento"),
    opportunityId: opportunity.id,
    ownerId: opportunity.ownerId,
    status: requireText(input.agendaStatus, existing?.status || "Programada"),
    place: requireText(input.agendaPlace, existing?.place || "Por definir"),
  };

  if (existing) {
    Object.assign(existing, agendaItem);
  } else {
    data.agenda.push(agendaItem);
  }
}

function normalizeGestion(input, existing = {}) {
  return {
    ...existing,
    agendaId: requireText(input.agendaId, existing.agendaId),
    opportunityId: requireText(input.opportunityId, existing.opportunityId),
    company: requireText(input.company, existing.company),
    ownerId: requireText(input.ownerId, existing.ownerId),
    type: requireText(input.type, existing.type || "Llamada"),
    date: requireText(input.date, existing.date || new Date().toISOString().slice(0, 10)),
    time: requireText(input.time, existing.time || "09:00"),
    status: requireText(input.status, existing.status || "Programada"),
    place: requireText(input.place, existing.place),
    locationLabel: requireText(input.locationLabel, existing.locationLabel || input.place),
    source: requireText(input.source, existing.source || "CRM"),
    note: requireText(input.note, existing.note),
    result: requireText(input.result, existing.result),
    updatedAt: new Date().toISOString(),
  };
}

async function handleApi(req, res, url) {
  const data = readData();
  const model = buildViewModel(data);
  const parts = url.pathname.split("/").filter(Boolean);

  if (url.pathname === "/api/health") {
    sendJson(res, { ok: true, service: "konfi-crm-api", timestamp: new Date().toISOString() });
    return;
  }

  if (url.pathname === "/api/bootstrap") {
    sendJson(res, model);
    return;
  }

  if (url.pathname === "/api/kpis") {
    sendJson(res, model.kpis);
    return;
  }

  if (url.pathname === "/api/pipeline") {
    sendJson(res, model.pipeline);
    return;
  }

  if (url.pathname === "/api/agenda") {
    const ownerId = url.searchParams.get("ownerId");
    sendJson(res, ownerId ? model.agenda.filter((item) => item.ownerId === ownerId) : model.agenda);
    return;
  }

  if (url.pathname === "/api/auth/login" && req.method === "POST") {
    try {
      const input = await readBody(req);
      const username = requireText(input.username).toLowerCase();
      const password = requireText(input.password);
      const user = data.users.find((item) => {
        const userName = requireText(item.username || item.email || item.name).toLowerCase();
        const email = requireText(item.email).toLowerCase();
        const expectedPassword = requireText(item.password, "konfi123");
        return (userName === username || email === username) && expectedPassword === password;
      });

      if (!user) {
        sendJson(res, { error: "Invalid credentials" }, 401);
        return;
      }

      sendJson(res, { ...buildViewModel(data), activeUserId: user.id });
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (url.pathname === "/api/users" && req.method === "GET") {
    sendJson(res, data.users);
    return;
  }

  if (url.pathname === "/api/users" && req.method === "POST") {
    try {
      const input = await readBody(req);
      if (!requireText(input.name)) {
        sendJson(res, { error: "Name is required" }, 400);
        return;
      }
      if (!requireText(input.email) || !requireText(input.password)) {
        sendJson(res, { error: "Email and password are required" }, 400);
        return;
      }
      if (duplicateUser(data, input)) {
        sendJson(res, { error: "User email, username or DUI already exists" }, 409);
        return;
      }
      const user = {
        id: `u-${Date.now()}`,
        ...normalizeUser(input),
      };
      data.users.push(user);
      writeData(data);
      sendJson(res, { ...buildViewModel(data), activeUserId: user.id }, 201);
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (parts[1] === "users" && parts[2]) {
    const index = data.users.findIndex((item) => item.id === parts[2]);

    if (req.method === "GET") {
      const found = data.users.find((item) => item.id === parts[2]);
      sendJson(res, found || { error: "User not found" }, found ? 200 : 404);
      return;
    }

    if (req.method === "PUT" || req.method === "PATCH") {
      if (index === -1) {
        sendJson(res, { error: "User not found" }, 404);
        return;
      }
      try {
        const input = await readBody(req);
        if (duplicateUser(data, input, parts[2])) {
          sendJson(res, { error: "User email, username or DUI already exists" }, 409);
          return;
        }
        data.users[index] = normalizeUser(input, data.users[index]);
        writeData(data);
        sendJson(res, { ...buildViewModel(data), activeUserId: data.users[index].id });
      } catch (error) {
        sendJson(res, { error: "Invalid request body" }, 400);
      }
      return;
    }

    if (req.method === "DELETE") {
      if (index === -1) {
        sendJson(res, { error: "User not found" }, 404);
        return;
      }
      const hasWork =
        data.opportunities.some((item) => item.ownerId === parts[2]) ||
        data.agenda.some((item) => item.ownerId === parts[2]);
      if (hasWork) {
        sendJson(res, { error: "User has assigned opportunities or agenda" }, 409);
        return;
      }
      data.users.splice(index, 1);
      writeData(data);
      sendJson(res, buildViewModel(data));
      return;
    }

    sendJson(res, { error: "Method not allowed" }, 405);
    return;
  }

  if (parts[1] === "agenda" && parts[2] && (req.method === "PUT" || req.method === "PATCH")) {
    const index = data.agenda.findIndex((item) => item.id === parts[2]);
    if (index === -1) {
      sendJson(res, { error: "Agenda item not found" }, 404);
      return;
    }

    try {
      const input = await readBody(req);
      const allowedStatuses = new Set(["Programada", "En visita", "Realizada", "Pendiente", "Cancelada", "Reprogramada"]);
      const current = data.agenda[index];
      const nextStatus = requireText(input.status, current.status);
      data.agenda[index] = {
        ...current,
        status: allowedStatuses.has(nextStatus) ? nextStatus : current.status,
        result: requireText(input.result, current.result),
        checkInAt: input.status === "En visita" ? new Date().toISOString() : current.checkInAt,
        completedAt: input.status === "Realizada" ? new Date().toISOString() : current.completedAt,
      };
      writeData(data);
      sendJson(res, buildViewModel(data));
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (parts[1] === "customers" && parts[2] && (req.method === "PUT" || req.method === "PATCH")) {
    try {
      const input = await readBody(req);
      const id = customerKey(parts[2]);
      const index = data.customers.findIndex((item) => item.id === id);
      const existing = index >= 0 ? data.customers[index] : { id };
      const customer = normalizeCustomer(input, existing);
      customer.id = id;

      if (index >= 0) {
        data.customers[index] = customer;
      } else {
        data.customers.push(customer);
      }

      data.opportunities = data.opportunities.map((opportunity) =>
        (opportunity.customerId || customerKey(opportunity.company)) === id
          ? {
              ...opportunity,
              customerId: id,
              company: customer.commercialName || opportunity.company,
              phone: customer.phone || opportunity.phone,
              responsible: customer.manager || opportunity.responsible,
              segment: customer.businessLine || opportunity.segment,
              location: customer.address || opportunity.location,
            }
          : opportunity,
      );

      data.gestiones = data.gestiones.map((gestion) =>
        customerKey(gestion.company) === id ? { ...gestion, company: customer.commercialName || gestion.company } : gestion,
      );

      writeData(data);
      sendJson(res, buildViewModel(data));
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (url.pathname === "/api/gestiones" && req.method === "POST") {
    try {
      const input = await readBody(req);
      const opportunity = data.opportunities.find((item) => item.id === input.opportunityId);
      if (!opportunity) {
        sendJson(res, { error: "Opportunity not found" }, 404);
        return;
      }
      const gestion = {
        id: `ges-${Date.now()}`,
        createdAt: new Date().toISOString(),
        ...normalizeGestion({
          ...input,
          company: input.company || opportunity.company,
          ownerId: input.ownerId || opportunity.ownerId,
        }),
      };
      data.gestiones.push(gestion);
      if (gestion.status === "Programada") {
        data.agenda.push({
          id: `ag-${gestion.id}`,
          gestionId: gestion.id,
          date: gestion.date,
          time: gestion.time || "09:00",
          type: gestion.type || "Gestion",
          opportunityId: opportunity.id,
          ownerId: gestion.ownerId || opportunity.ownerId,
          status: "Programada",
          place: requireText(input.place, input.note || "Por definir"),
        });
      }
      writeData(data);
      sendJson(res, buildViewModel(data), 201);
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (parts[1] === "gestiones" && parts[2]) {
    const index = data.gestiones.findIndex((item) => item.id === parts[2]);

    if (req.method === "PUT" || req.method === "PATCH") {
      if (index === -1) {
        sendJson(res, { error: "Gestion not found" }, 404);
        return;
      }
      try {
        const input = await readBody(req);
        data.gestiones[index] = normalizeGestion(input, data.gestiones[index]);
        writeData(data);
        sendJson(res, buildViewModel(data));
      } catch (error) {
        sendJson(res, { error: "Invalid request body" }, 400);
      }
      return;
    }

    if (req.method === "DELETE") {
      if (index === -1) {
        sendJson(res, { error: "Gestion not found" }, 404);
        return;
      }
      data.gestiones.splice(index, 1);
      data.agenda = data.agenda.filter((item) => item.gestionId !== parts[2]);
      writeData(data);
      sendJson(res, buildViewModel(data));
      return;
    }

    sendJson(res, { error: "Method not allowed" }, 405);
    return;
  }

  if (url.pathname === "/api/opportunities" && req.method === "POST") {
    try {
      const input = await readBody(req);
      if (!requireText(input.company) || !requireText(input.ownerId)) {
        sendJson(res, { error: "Company and ownerId are required" }, 400);
        return;
      }
      const opportunity = {
        id: `opp-${Date.now()}`,
        ...normalizeOpportunity(input),
      };
      data.opportunities.push(opportunity);
      upsertAgendaForOpportunity(data, opportunity, input);
      writeData(data);
      sendJson(res, buildViewModel(data), 201);
    } catch (error) {
      sendJson(res, { error: "Invalid request body" }, 400);
    }
    return;
  }

  if (parts[1] === "opportunities" && parts[2]) {
    const index = data.opportunities.findIndex((item) => item.id === parts[2]);

    if (req.method === "GET") {
      const found = model.opportunities.find((item) => item.id === parts[2]);
      sendJson(res, found || { error: "Opportunity not found" }, found ? 200 : 404);
      return;
    }

    if (req.method === "PUT" || req.method === "PATCH") {
      if (index === -1) {
        sendJson(res, { error: "Opportunity not found" }, 404);
        return;
      }
      try {
        const input = await readBody(req);
        const opportunity = normalizeOpportunity(input, data.opportunities[index]);
        data.opportunities[index] = opportunity;
        upsertAgendaForOpportunity(data, opportunity, input);
        writeData(data);
        sendJson(res, buildViewModel(data));
      } catch (error) {
        sendJson(res, { error: "Invalid request body" }, 400);
      }
      return;
    }

    if (req.method === "DELETE") {
      if (index === -1) {
        sendJson(res, { error: "Opportunity not found" }, 404);
        return;
      }
      data.opportunities.splice(index, 1);
      data.agenda = data.agenda.filter((item) => item.opportunityId !== parts[2]);
      writeData(data);
      sendJson(res, buildViewModel(data));
      return;
    }

    sendJson(res, { error: "Method not allowed" }, 405);
    return;
  }

  sendJson(res, { error: "Endpoint not found" }, 404);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type,Authorization",
    });
    res.end();
    return;
  }

  if (url.pathname.startsWith("/api/")) {
    handleApi(req, res, url);
    return;
  }

  const requested = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
  const filePath = path.resolve(webDir, requested);
  sendFile(res, filePath, webDir);
});

server.listen(PORT, HOST, () => {
  console.log(`KONFI CRM listo en http://${HOST}:${PORT}`);
});
