# KONFI CRM + App movil

Este repositorio publica el CRM web y la API que consume la app movil Flutter.

URL de produccion prevista:

```text
https://induccion-gerencia-comercial.onrender.com
```

## Publicacion en Render

Este proyecto debe publicarse como `Web Service` Node, no como `Static Site`.

- Runtime: `Node`
- Build command: `npm install`
- Start command: `npm start`
- Variable `HOST`: `0.0.0.0`
- Variable `DATA_PATH`: `/var/data/konfi-crm-seed.json`
- Disk persistente: `/var/data`

`render.yaml` ya contiene esta configuracion.

## Rutas principales

- CRM web: `/`
- API health: `/api/health`
- Bootstrap de datos app/CRM: `/api/bootstrap`

## APK conectada a esta URL

Desde una copia local con Flutter instalado:

```bat
build-flutter-apk.bat https://induccion-gerencia-comercial.onrender.com
```

La APK se genera en:

```text
mobile-app\build\app\outputs\flutter-apk\app-debug.apk
```

## Nota de migracion

La web anterior de induccion fue reemplazada por el CRM web y la API.
