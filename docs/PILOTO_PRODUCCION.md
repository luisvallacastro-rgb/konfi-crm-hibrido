# Piloto de produccion KONFI CRM + App movil

Objetivo: publicar el CRM web y la API en una URL HTTPS publica, compilar la APK apuntando a esa URL y probar el flujo completo con tres usuarios reales.

## 1. Arquitectura del piloto

```text
Vendedor 1 APK
Vendedor 2 APK  ->  URL publica HTTPS  ->  CRM web + API Node  ->  DATA_PATH persistente
Vendedor 3 APK
Gerencia CRM web
```

El CRM web y la API se publican como un solo servicio Node. La app Flutter no se conecta a la computadora local; se compila con `API_BASE_URL` apuntando a la URL publica.

## 2. Publicar CRM + API

Opcion directa con Render:

1. Sube este proyecto a GitHub.
2. En Render crea un `Blueprint` o `Web Service` desde el repositorio.
3. Si usas Blueprint, Render leera `render.yaml`.
4. Si lo configuras manualmente:
   - Runtime: `Node`
   - Build command: `npm install`
   - Start command: `npm start`
   - Environment variables:
     - `HOST=0.0.0.0`
     - `NODE_ENV=production`
     - `DATA_PATH=/var/data/konfi-crm-seed.json`
   - Disk persistente:
     - Mount path: `/var/data`
     - Size: `1 GB`
5. Cuando termine el despliegue, usa esta URL HTTPS:

```text
https://induccion-gerencia-comercial.onrender.com
```

## 3. Verificar que la URL publica funciona

Abre estas rutas desde el navegador:

```text
https://TU-URL-PUBLICA/
https://TU-URL-PUBLICA/api/health
```

La primera debe abrir el CRM. La segunda debe responder JSON de salud.

## 4. Compilar la APK conectada a produccion

Desde la carpeta principal del proyecto:

```bat
build-flutter-apk.bat https://induccion-gerencia-comercial.onrender.com
```

Ejemplo:

```bat
build-flutter-apk.bat https://induccion-gerencia-comercial.onrender.com
```

La APK se genera en:

```text
mobile-app\build\app\outputs\flutter-apk\app-debug.apk
```

Copiala a los tres telefonos y permite la instalacion desde origen desconocido si Android lo solicita.

## 5. Prueba con tres usuarios

### Usuario A: perfilamiento

1. Instala la APK.
2. Abre la app.
3. Crea una cuenta nueva con datos reales del vendedor.
4. Completa perfil: nombre, apellido, DUI, direccion, telefono, correo y clave.
5. En el CRM web entra a `Vendedores`.
6. Confirma que el vendedor aparece.

### Usuario B: oportunidad desde app

1. Instala la APK.
2. Crea o inicia sesion con su perfil.
3. Entra a `Cartera`.
4. Presiona `+`.
5. Registra una oportunidad con empresa, producto, monto, etapa, cierre, telefono y comentario.
6. En CRM web revisa `Seguimiento` y `Vendedores`.
7. Confirma que la oportunidad llego al CRM.

### Usuario C: agenda y respuesta

1. En CRM web crea una oportunidad para ese vendedor.
2. Llena la agenda inicial: fecha, hora, tipo y lugar.
3. En la APK entra a `Agenda`.
4. Abre la visita.
5. Registra check-in, resultado y nota.
6. En CRM web entra a `Respuestas`.
7. Confirma que aparece como fila tipo correo con estado `Pendiente` o `Cumplido`.

## 6. Checklist de aprobacion

- Cada vendedor puede registrarse desde la APK.
- El CRM recibe los perfiles creados desde app.
- Una oportunidad creada en CRM aparece en la APK del vendedor asignado.
- Una oportunidad creada en APK aparece en el CRM.
- La agenda se visualiza en ambos lados.
- Las respuestas de campo llegan al modulo `Respuestas`.
- El estado `Pendiente` o `Cumplido` es visible en la bandeja.
- Los tres telefonos usan la misma URL publica, no `127.0.0.1`.

## 7. Notas importantes

- Esta es una publicacion de piloto. La base actual sigue siendo JSON, ahora preparada para usar `DATA_PATH` persistente en el servidor.
- Para produccion formal conviene migrar los datos a PostgreSQL, agregar autenticacion robusta, roles por usuario y backups automaticos.
- Si Render duerme el servicio en plan gratis, la primera carga puede tardar unos segundos.
