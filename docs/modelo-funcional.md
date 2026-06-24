# Modelo funcional inicial

## Flujo comercial

1. Prospeccion
2. Contacto inicial
3. Deteccion de necesidades
4. Presentacion de solucion
5. Manejo de objeciones
6. Cierre de ventas
7. Compilado de informacion
8. Postventa

## Roles

- Ejecutivo de ventas: gestiona prospectos, agenda, visitas, necesidades, objeciones y cierres.
- Gerente de ventas: mide KPIs, reasigna agenda, supervisa pipeline y conversion.
- Asistente de ventas: coordina muestras, material y soporte al ejecutivo.
- Encargado de digitalizacion: recibe informacion completa para preparar produccion.
- Gerente de produccion y operaciones: valida anticipo, documentos y orden de produccion.
- Atencion al cliente: atiende reclamos, garantias, NPS y seguimiento postventa.

## Entidades principales

- Usuario
- Rol
- Prospecto / cliente
- Oportunidad
- Etapa
- Actividad de agenda
- Visita
- Formulario de etapa
- Solicitud de muestras
- Objecion
- Pedido
- Seguimiento postventa
- Reclamo / garantia
- KPI

## KPIs iniciales

- Prospectos activos
- Conversion por etapa
- Reuniones programadas
- Visitas realizadas
- Oportunidades calientes
- Monto estimado de pipeline
- Tasa de cierre
- NPS postventa
- Reclamos abiertos

## Regla central

La app movil y el CRM web no se conectan directo a la base de datos. Ambos consumen la misma API central para mantener seguridad, permisos y reglas de negocio en un solo lugar.
