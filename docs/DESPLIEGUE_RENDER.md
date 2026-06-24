# Despliegue rapido en Render

Esta guia publica el CRM web y la API en una URL publica para que la APK pueda conectarse desde telefonos reales.

## 1. Subir el proyecto a GitHub

Desde la raiz del proyecto, subir el codigo a un repositorio GitHub.

No subir:

- `.tools/`
- `mobile-app/build/`
- `docs-output/`
- logs locales

El archivo `.gitignore` ya esta preparado para excluir esos archivos.

## 2. Crear servicio en Render

1. Entrar a Render.
2. Crear `New Web Service`.
3. Conectar el repositorio GitHub.
4. Seleccionar el proyecto.
5. Configuracion:

```text
Environment: Node
Build Command: npm install
Start Command: npm start
```

Variables:

```text
NODE_ENV=production
HOST=0.0.0.0
```

Render asignara una URL similar a:

```text
https://konfi-crm-piloto.onrender.com
```

## 3. Validar URL publica

Abrir:

```text
https://TU-URL-PUBLICA/
```

Debe cargar el CRM web.

Abrir:

```text
https://TU-URL-PUBLICA/api/health
```

Debe devolver:

```json
{
  "ok": true,
  "service": "konfi-crm-api"
}
```

## 4. Compilar APK para esa URL

Cuando la URL publica ya funcione:

```powershell
.\build-flutter-apk.bat https://TU-URL-PUBLICA
```

Ejemplo:

```powershell
.\build-flutter-apk.bat https://konfi-crm-piloto.onrender.com
```

APK:

```text
mobile-app/build/app/outputs/flutter-apk/app-debug.apk
```

## 5. Instalar APK en telefonos

Enviar el APK a los tres usuarios de prueba.

Cada usuario debe:

1. Instalar APK.
2. Crear perfil o iniciar sesion.
3. Crear una oportunidad.
4. Avisar para validar en CRM > Vendedores y CRM > Seguimiento.

## 6. Riesgo conocido del piloto

Este piloto usa `backend/data/seed.json` como almacenamiento.

En Render Free, si el servicio se reinicia o redeploya, los datos pueden perderse o volver al archivo base del repositorio.

Para piloto corto sirve. Para operacion real se debe migrar a PostgreSQL.

