# KONFI CRM Mobile

App Flutter para vendedores conectada al CRM.

## Backend

Por defecto la app usa:

- `API_BASE_URL`: `http://127.0.0.1:8099`
- `API_PATH_PREFIX`: `/api/crm`

Para el Sistema Gerencial publicado:

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=https://sistema-gerencial.onrender.com \
  --dart-define=API_PATH_PREFIX=/api/crm
```

Para el CRM antiguo:

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=https://induccion-gerencia-comercial.onrender.com \
  --dart-define=API_PATH_PREFIX=/api
```

En Windows, desde la carpeta raiz del proyecto:

```bat
build-flutter-apk.bat https://sistema-gerencial.onrender.com /api/crm
```
