import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8099',
);
const apiPathPrefix = String.fromEnvironment(
  'API_PATH_PREFIX',
  defaultValue: '/api/crm',
);
const previewUsername = String.fromEnvironment('PREVIEW_USERNAME');
const previewPassword = String.fromEnvironment('PREVIEW_PASSWORD');

class SessionStorage {
  static const _channel = MethodChannel('com.kmi.ventas/session');

  static Future<SalesUser?> read() async {
    try {
      final raw = await _channel.invokeMethod<String>('read');
      if (raw == null || raw.isEmpty) return null;
      return SalesUser.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on FormatException {
      await clear();
      return null;
    }
  }

  static Future<void> write(SalesUser user) async {
    try {
      await _channel.invokeMethod<void>('write', jsonEncode(user.toJson()));
    } on PlatformException {
      // La app sigue operativa aunque el almacenamiento nativo no responda.
    } on MissingPluginException {
      // Permite ejecutar las pruebas y la vista web sin el canal Android.
    }
  }

  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on PlatformException {
      // No bloquea el cierre visual de sesion.
    } on MissingPluginException {
      // Permite ejecutar las pruebas y la vista web sin el canal Android.
    }
  }
}

void main() {
  runApp(const KonfiSalesApp());
}

class KonfiSalesApp extends StatelessWidget {
  const KonfiSalesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KMI Ventas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.page,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.green,
          brightness: Brightness.dark,
          primary: AppColors.green,
          secondary: AppColors.cyan,
          surface: AppColors.surface,
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const SalesShell(),
    );
  }
}

class AppColors {
  static const page = Color(0xFF111A2D);
  static const panel = Color(0xCC17233A);
  static const surface = Color(0xFF17233A);
  static const surfaceStrong = Color(0xFF243452);
  static const green = Color(0xFF72F5D1);
  static const cyan = Color(0xFF68A8FF);
  static const yellow = Color(0xFFF0AF4F);
  static const red = Color(0xFFFF657E);
  static const muted = Color(0xFF9FB0C7);
  static const line = Color(0x336B82A6);
  static const ink = Color(0xFFF4F8FF);
}

class SalesShell extends StatefulWidget {
  const SalesShell({super.key});

  @override
  State<SalesShell> createState() => _SalesShellState();
}

class _SalesShellState extends State<SalesShell> {
  final KonfiApiClient api = const KonfiApiClient(apiBaseUrl);
  SalesStore? store;
  SalesUser? registeredSeller;
  int tabIndex = 0;
  bool loading = true;
  String? offlineReason;
  Timer? assignmentPoller;
  bool assignmentBaselineReady = false;
  final Set<String> knownAssignmentIds = {};
  final Set<String> unreadAssignmentIds = {};

  SalesUser get seller =>
      registeredSeller ??
      store?.currentSeller ??
      SalesStore.seed().currentSeller;

  @override
  void initState() {
    super.initState();
    unawaited(loadInitialSession());
  }

  @override
  void dispose() {
    assignmentPoller?.cancel();
    super.dispose();
  }

  Future<void> loadInitialSession() async {
    if (previewUsername.isEmpty || previewPassword.isEmpty) {
      final restoredSeller = await SessionStorage.read();
      if (restoredSeller != null && mounted) {
        setState(() => registeredSeller = restoredSeller);
      }
      await loadStore();
      if (restoredSeller != null && mounted) {
        _activateAssignmentMonitoring(
          (store ?? SalesStore.seed()).withSeller(restoredSeller),
        );
      }
      return;
    }

    try {
      final loaded = await api.login(
        const LoginDraft(username: previewUsername, password: previewPassword),
        previous: store,
      );
      if (!mounted) return;
      final loggedSeller = loaded.currentSeller;
      await SessionStorage.write(loggedSeller);
      setState(() {
        registeredSeller = loggedSeller;
        store = loaded.withSeller(loggedSeller);
        offlineReason = null;
        loading = false;
        tabIndex = 0;
      });
      _activateAssignmentMonitoring(loaded.withSeller(loggedSeller));
    } catch (_) {
      if (!mounted) return;
      await loadStore();
      if (!mounted) return;
      setState(() {
        offlineReason = 'No se pudo abrir la vista previa de $previewUsername.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeStore = store;
    if (loading && activeStore == null) {
      return const Scaffold(
        body: Stack(
          children: [
            DarkBackdrop(),
            Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }

    final safeStore = activeStore ?? SalesStore.seed();
    if (registeredSeller == null) {
      return Scaffold(
        body: Stack(
          children: [
            const DarkBackdrop(),
            SafeArea(
              child: SellerRegistrationPage(
                store: safeStore,
                offlineReason: offlineReason,
                onRetry: () => unawaited(loadStore()),
                onRegister: registerSeller,
                onLogin: loginSeller,
                onCreateSeller: createSeller,
              ),
            ),
          ],
        ),
      );
    }

    final managerMode = seller.isManager;
    final pages = managerMode
        ? [
            ManagerHomePage(
              store: safeStore,
              onAssignOpportunity: () => openManagerAssignmentSheet(),
              onOpenOpportunity: openOpportunitySheet,
              onSync: loadStore,
            ),
            ManagerTeamPage(
              store: safeStore,
              onAssignOpportunity: openManagerAssignmentSheet,
              onOpenOpportunity: openOpportunitySheet,
            ),
            ManagerPipelinePage(
              store: safeStore,
              onOpenOpportunity: openOpportunitySheet,
            ),
          ]
        : [
            OpportunitiesPage(
              store: safeStore,
              unreadOpportunityIds: unreadAssignmentIds,
              onMarkAssignmentsRead: markAssignmentsRead,
              onNewOpportunity: () => openOpportunityEditorSheet(),
              onOpenOpportunity: openOpportunitySheet,
              onEditOpportunity: (opportunity) =>
                  openOpportunityEditorSheet(opportunity: opportunity),
              onSync: loadStore,
            ),
            AgendaPage(
              store: safeStore,
              onStatusChange: syncAgendaStatus,
              onOpenOpportunity: openOpportunitySheet,
              onCaptureForm: openFormCaptureSheet,
              onNewGestion: openScheduledGestionSheet,
            ),
            PipelinePage(
              store: safeStore,
              onOpenOpportunity: openOpportunitySheet,
            ),
            FormsPage(store: safeStore, onCaptureForm: openFormCaptureSheet),
            KpiPage(store: safeStore),
          ];

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          const DarkBackdrop(),
          SafeArea(
            child: Column(
              children: [
                AppHeader(
                  seller: seller,
                  managerMode: managerMode,
                  onNewOpportunity: managerMode
                      ? () => openManagerAssignmentSheet()
                      : () => openOpportunityEditorSheet(),
                  onOpenProfile: openProfileSheet,
                ),
                if (offlineReason != null)
                  OfflineBanner(
                    message: offlineReason!,
                    onRetry: () => unawaited(loadStore()),
                  ),
                Expanded(
                  child: IndexedStack(index: tabIndex, children: pages),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SalesBottomNav(
        managerMode: managerMode,
        selectedIndex: tabIndex,
        onSelected: (index) => setState(() => tabIndex = index),
      ),
    );
  }

  void refresh() {
    setState(() {});
  }

  Future<void> loadStore() async {
    setState(() => loading = true);
    try {
      final loaded = await api.loadStore(previous: store);
      if (!mounted) return;
      final nextStore = registeredSeller == null
          ? loaded
          : loaded.withSeller(registeredSeller!);
      final newAssignments = assignmentBaselineReady
          ? nextStore.myOpportunities
              .where(
                (item) =>
                    !knownAssignmentIds.contains(item.id) &&
                    item.source != 'App vendedor',
              )
              .toList()
          : <Opportunity>[];
      setState(() {
        store = nextStore;
        knownAssignmentIds.addAll(
          nextStore.myOpportunities.map((item) => item.id),
        );
        unreadAssignmentIds.addAll(newAssignments.map((item) => item.id));
        offlineReason = null;
        loading = false;
      });
      if (newAssignments.isNotEmpty) _showAssignmentAlert(newAssignments);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        store ??= SalesStore.seed();
        offlineReason = 'Modo offline: no se pudo conectar con $apiBaseUrl';
        loading = false;
      });
    }
  }

  void registerSeller(SalesUser seller) {
    final activeStore = store ?? SalesStore.seed();
    setState(() {
      registeredSeller = seller;
      store = activeStore.withSeller(seller);
      tabIndex = 0;
    });
    unawaited(SessionStorage.write(seller));
    _activateAssignmentMonitoring(activeStore.withSeller(seller));
  }

  Future<void> createSeller(SellerDraft draft) async {
    final current = store ?? SalesStore.seed();
    try {
      final loaded = await api.createSeller(draft, previous: current);
      final created = loaded.currentSeller;
      if (!mounted) return;
      await SessionStorage.write(created);
      setState(() {
        registeredSeller = created;
        store = loaded.withSeller(created);
        offlineReason = null;
        tabIndex = 0;
      });
      _activateAssignmentMonitoring(loaded.withSeller(created));
    } catch (error) {
      final localSeller = SalesUser.localFromDraft(draft);
      if (!mounted) return;
      setState(() {
        registeredSeller = localSeller;
        store = current.withAddedSeller(localSeller).withSeller(localSeller);
        offlineReason =
            'Perfil creado localmente; pendiente de sincronizar con CRM.';
        tabIndex = 0;
      });
      _activateAssignmentMonitoring(current.withSeller(localSeller));
    }
  }

  Future<void> loginSeller(LoginDraft draft) async {
    final current = store ?? SalesStore.seed();
    try {
      final loaded = await api.login(draft, previous: current);
      final loggedSeller = loaded.currentSeller;
      if (!mounted) return;
      await SessionStorage.write(loggedSeller);
      setState(() {
        registeredSeller = loggedSeller;
        store = loaded.withSeller(loggedSeller);
        offlineReason = null;
        tabIndex = 0;
      });
      _activateAssignmentMonitoring(loaded.withSeller(loggedSeller));
    } catch (error) {
      if (!mounted) return;
      final errorText = error.toString();
      final isAuthError = errorText.contains('API 401');
      setState(() {
        offlineReason = isAuthError
            ? 'Usuario o contrasena incorrectos.'
            : 'No se pudo conectar con CRM. Verifica que $apiBaseUrl este activo.';
      });
    }
  }

  void switchSeller() {
    unawaited(SessionStorage.clear());
    assignmentPoller?.cancel();
    assignmentPoller = null;
    assignmentBaselineReady = false;
    knownAssignmentIds.clear();
    unreadAssignmentIds.clear();
    setState(() {
      registeredSeller = null;
      tabIndex = 0;
    });
  }

  void _activateAssignmentMonitoring(SalesStore activeStore) {
    if (activeStore.currentSeller.isManager) {
      assignmentPoller?.cancel();
      assignmentPoller = null;
      assignmentBaselineReady = false;
      knownAssignmentIds.clear();
      unreadAssignmentIds.clear();
      return;
    }
    knownAssignmentIds
      ..clear()
      ..addAll(activeStore.myOpportunities.map((item) => item.id));
    unreadAssignmentIds.clear();
    assignmentBaselineReady = true;
    assignmentPoller ??= Timer.periodic(const Duration(seconds: 12), (_) {
      if (registeredSeller != null && !loading) unawaited(loadStore());
    });
  }

  void markAssignmentsRead() {
    if (unreadAssignmentIds.isEmpty) return;
    setState(unreadAssignmentIds.clear);
  }

  void _showAssignmentAlert(List<Opportunity> assignments) {
    final first = assignments.first;
    final message = assignments.length == 1
        ? 'Se te ha asignado una nueva oportunidad: ${first.company}'
        : 'Se te asignaron ${assignments.length} oportunidades nuevas';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surfaceStrong,
          elevation: 12,
          margin: const EdgeInsets.fromLTRB(18, 0, 18, 96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.green, width: 0.8),
          ),
          content: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.notifications_active_rounded,
                  color: AppColors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Ver',
            textColor: AppColors.green,
            onPressed: () => setState(() => tabIndex = 0),
          ),
        ),
      );
  }

  void openProfileSheet() {
    final activeSeller = registeredSeller;
    if (activeSeller == null) return;
    if (activeSeller.isManager) {
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => ManagerProfileSheet(
          user: activeSeller,
          onLogout: () {
            Navigator.pop(context);
            switchSeller();
          },
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ProfileSheet(
        seller: activeSeller,
        onSave: (draft) {
          Navigator.pop(context);
          unawaited(updateSeller(draft));
        },
        onDelete: () {
          Navigator.pop(context);
          unawaited(deleteSeller());
        },
        onLogout: () {
          Navigator.pop(context);
          switchSeller();
        },
      ),
    );
  }

  Future<void> updateSeller(SellerDraft draft) async {
    final current = store ?? SalesStore.seed();
    final activeSeller = registeredSeller;
    if (activeSeller == null) return;
    final localSeller = activeSeller.updatedFromDraft(draft);
    setState(() {
      registeredSeller = localSeller;
      store = current.withUpdatedSeller(localSeller).withSeller(localSeller);
    });

    try {
      final loaded = await api.updateSeller(
        activeSeller.id,
        draft,
        previous: store,
      );
      final updated = loaded.currentSeller;
      if (!mounted) return;
      await SessionStorage.write(updated);
      setState(() {
        registeredSeller = updated;
        store = loaded.withSeller(updated);
        offlineReason = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'Perfil actualizado localmente; pendiente de sincronizar.';
      });
    }
  }

  Future<void> deleteSeller() async {
    final activeSeller = registeredSeller;
    if (activeSeller == null) return;
    try {
      final loaded = await api.deleteSeller(activeSeller.id, previous: store);
      if (!mounted) return;
      await SessionStorage.clear();
      setState(() {
        registeredSeller = null;
        store = loaded;
        offlineReason = null;
        tabIndex = 0;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'No se pudo eliminar el perfil. Revisa si tiene agenda u oportunidades asignadas.';
      });
    }
  }

  Future<void> syncAgendaStatus(String agendaId, VisitStatus status) async {
    final current = store;
    if (current == null) return;
    current.updateAgendaStatus(agendaId, status);
    refresh();

    try {
      final loaded = await api.updateAgendaStatus(
        agendaId,
        status,
        previous: current,
      );
      if (!mounted) return;
      setState(() {
        store = loaded;
        offlineReason = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason = 'Cambio guardado localmente; pendiente de sincronizar.';
      });
    }
  }

  void openOpportunitySheet(String opportunityId) {
    final activeStore = store ?? SalesStore.seed();
    final opportunity = activeStore.opportunityById(opportunityId);
    final agenda = activeStore.agendaForOpportunity(opportunityId);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => OpportunityActionSheet(
        store: activeStore,
        opportunity: opportunity,
        agenda: agenda,
        onSaveGestion: (draft) =>
            saveOpportunityGestion(opportunity.id, draft, agenda),
        onStatusChange: (agendaId, status) {
          Navigator.pop(context);
          return syncAgendaStatus(agendaId, status);
        },
        onCaptureForm: () {
          Navigator.pop(context);
          openFormCaptureSheet(opportunity.stageId);
        },
      ),
    );
  }

  void openFormCaptureSheet(int stageId) {
    final activeStore = store ?? SalesStore.seed();
    final form = activeStore.formForStage(stageId);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FormCaptureSheet(
        form: form,
        onSave: (values) {
          activeStore.saveFormResponse(form.id, values);
          Navigator.pop(context);
          refresh();
        },
      ),
    );
  }

  void openOpportunityEditorSheet({Opportunity? opportunity}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => OpportunityEditorSheet(
        store: store ?? SalesStore.seed(),
        opportunity: opportunity,
        onSave: (draft) {
          Navigator.pop(context);
          unawaited(saveOpportunityDraft(draft, opportunity: opportunity));
        },
        onDelete: opportunity == null
            ? null
            : () {
                Navigator.pop(context);
                unawaited(deleteOpportunity(opportunity.id));
              },
      ),
    );
  }

  void openManagerAssignmentSheet([SalesUser? assignedSeller]) {
    final activeStore = store ?? SalesStore.seed();
    if (assignedSeller == null) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => ManagerSellerPickerSheet(
          store: activeStore,
          onSelected: (seller) {
            Navigator.pop(context);
            Future<void>.delayed(const Duration(milliseconds: 180), () {
              if (mounted) openManagerAssignmentSheet(seller);
            });
          },
        ),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => OpportunityEditorSheet(
        store: activeStore.withSeller(assignedSeller),
        onSave: (draft) {
          Navigator.pop(context);
          unawaited(saveManagerOpportunityDraft(draft, assignedSeller));
        },
      ),
    );
  }

  Future<void> saveManagerOpportunityDraft(
    OpportunityDraft draft,
    SalesUser assignedSeller,
  ) async {
    final current = store ?? SalesStore.seed();
    try {
      final loaded = await api.createOpportunity(
        draft,
        assignedSeller.id,
        previous: current,
        source: 'CRM gerencia',
      );
      if (!mounted) return;
      setState(() {
        store = loaded.withSeller(current.currentSeller);
        offlineReason = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surfaceStrong,
          content: Text(
            'Oportunidad asignada a ${assignedSeller.firstName.isEmpty ? assignedSeller.name : assignedSeller.firstName}',
            style: const TextStyle(color: AppColors.ink),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'No se pudo asignar la oportunidad. Revisa la conexion.';
      });
    }
  }

  Future<void> saveOpportunityDraft(
    OpportunityDraft draft, {
    Opportunity? opportunity,
  }) async {
    final current = store ?? SalesStore.seed();
    current.saveOpportunityDraft(draft, opportunityId: opportunity?.id);
    setState(() => store = current);

    try {
      final loaded = opportunity == null
          ? await api.createOpportunity(
              draft,
              current.currentSeller.id,
              previous: current,
            )
          : await api.updateOpportunity(
              opportunity.id,
              draft,
              current.currentSeller.id,
              previous: current,
            );
      if (!mounted) return;
      setState(() {
        store = loaded;
        offlineReason = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'Oportunidad guardada localmente; pendiente de sincronizar.';
      });
    }
  }

  Future<void> deleteOpportunity(String opportunityId) async {
    final current = store ?? SalesStore.seed();
    current.deleteOpportunity(opportunityId);
    setState(() => store = current);

    try {
      final loaded = await api.deleteOpportunity(
        opportunityId,
        previous: current,
      );
      if (!mounted) return;
      setState(() {
        store = loaded;
        offlineReason = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'Oportunidad eliminada localmente; pendiente de sincronizar.';
      });
    }
  }

  Future<void> saveOpportunityGestion(
    String opportunityId,
    OpportunityGestionDraft draft,
    AgendaItem? agenda,
  ) async {
    final current = store;
    if (current == null) return;
    current.addVisitResult(
      opportunityId,
      draft.closureResult.isEmpty ? 'Gestion registrada' : draft.closureResult,
      draft.comment,
    );
    refresh();

    try {
      final loaded = await api.createGestion(
        opportunityId,
        draft,
        agenda: agenda,
        previous: current,
      );
      if (!mounted) return;
      setState(() {
        store = loaded.withSeller(current.currentSeller);
        offlineReason = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason =
            'Gestion guardada localmente; pendiente de sincronizar.';
      });
    }
  }

  void openScheduledGestionSheet() {
    final activeStore = store ?? SalesStore.seed();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ScheduledGestionSheet(
        store: activeStore,
        onSave: (draft) {
          Navigator.pop(context);
          unawaited(saveScheduledGestion(draft));
        },
      ),
    );
  }

  Future<void> saveScheduledGestion(ScheduledGestionDraft draft) async {
    final current = store;
    if (current == null) return;
    try {
      final loaded = await api.createScheduledGestion(draft, previous: current);
      if (!mounted) return;
      setState(() {
        store = loaded.withSeller(current.currentSeller);
        offlineReason = null;
        tabIndex = 1;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        offlineReason = 'No se pudo programar la gestion. Revisa la conexion.';
      });
    }
  }
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined, color: AppColors.yellow),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12)),
            ),
            TextButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

class SalesBottomNav extends StatelessWidget {
  const SalesBottomNav({
    required this.managerMode,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final bool managerMode;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const sellerItems = [
    _SalesNavItem(
      Icons.business_center_outlined,
      Icons.business_center,
      'Cartera',
    ),
    _SalesNavItem(
      Icons.calendar_today_outlined,
      Icons.calendar_today,
      'Agenda',
    ),
    _SalesNavItem(Icons.view_kanban_outlined, Icons.view_kanban, 'Etapas'),
    _SalesNavItem(Icons.assignment_outlined, Icons.assignment, 'Forms'),
    _SalesNavItem(Icons.query_stats_outlined, Icons.query_stats, 'KPIs'),
  ];

  static const managerItems = [
    _SalesNavItem(
      Icons.space_dashboard_outlined,
      Icons.space_dashboard,
      'Inicio',
    ),
    _SalesNavItem(Icons.groups_outlined, Icons.groups, 'Equipo'),
    _SalesNavItem(Icons.view_kanban_outlined, Icons.view_kanban, 'Pipeline'),
  ];

  @override
  Widget build(BuildContext context) {
    final items = managerMode ? managerItems : sellerItems;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                for (var index = 0; index < items.length; index++)
                  Expanded(
                    child: _SalesBottomNavButton(
                      item: items[index],
                      selected: selectedIndex == index,
                      onTap: () => onSelected(index),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SalesNavItem {
  const _SalesNavItem(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _SalesBottomNavButton extends StatelessWidget {
  const _SalesBottomNavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SalesNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.page : AppColors.ink;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Tooltip(
        message: item.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.green.withValues(alpha: 0.92)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  color: color,
                  size: selected ? 23 : 21,
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      color: color,
                      fontSize: 11.5,
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ManagerHomePage extends StatelessWidget {
  const ManagerHomePage({
    required this.store,
    required this.onAssignOpportunity,
    required this.onOpenOpportunity,
    required this.onSync,
    super.key,
  });

  final SalesStore store;
  final VoidCallback onAssignOpportunity;
  final ValueChanged<String> onOpenOpportunity;
  final Future<void> Function() onSync;

  @override
  Widget build(BuildContext context) {
    final active = store.opportunities.where(_isActiveOpportunity).toList();
    final team =
        store.sellers.where((item) => item.roleId == 'sales_exec').toList();
    final total = active.fold<double>(0, (sum, item) => sum + item.amount);
    final overdue = active.where(_isOverdueOpportunity).length;
    final won = store.opportunities
        .where((item) => item.status.toLowerCase() == 'ganada')
        .length;
    final lost = store.opportunities
        .where((item) => item.status.toLowerCase() == 'perdida')
        .length;
    final managerialOpportunityCount =
        store.managerialOpportunityCount ?? active.length;
    final managerialOpportunityTotal =
        store.managerialOpportunityTotal ?? total;
    final rankedTeam = [...team]..sort((a, b) {
        final aTotal = active
            .where((item) => item.ownerId == a.id)
            .fold<double>(0, (sum, item) => sum + item.amount);
        final bTotal = active
            .where((item) => item.ownerId == b.id)
            .fold<double>(0, (sum, item) => sum + item.amount);
        return bTotal.compareTo(aTotal);
      });

    return RefreshIndicator(
      onRefresh: onSync,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        children: [
          ManagerHeroCard(
            crmTotal: total,
            managerialTotal: managerialOpportunityTotal,
            managerialOpportunityCount: managerialOpportunityCount,
            crmOpportunityCount: active.length,
            sellerCount: team.length,
            onAssignOpportunity: onAssignOpportunity,
            onSync: onSync,
          ),
          const SizedBox(height: 18),
          const SectionTitle(
            eyebrow: 'Control comercial',
            title: 'Pulso del negocio',
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) => GridView.count(
              crossAxisCount: constraints.maxWidth >= 760 ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: constraints.maxWidth >= 760 ? 1.75 : 1.35,
              children: [
                ManagerMetricCard(
                  icon: Icons.warning_amber_rounded,
                  label: 'Vencidas',
                  value: '$overdue',
                  color: overdue > 0 ? AppColors.red : AppColors.green,
                ),
                ManagerMetricCard(
                  icon: Icons.task_alt_rounded,
                  label: 'Ganadas',
                  value: '$won',
                  color: AppColors.green,
                ),
                ManagerMetricCard(
                  icon: Icons.cancel_outlined,
                  label: 'Perdidas',
                  value: '$lost',
                  color: AppColors.red,
                ),
                ManagerMetricCard(
                  icon: Icons.event_available_outlined,
                  label: 'En agenda',
                  value: '${store.agenda.length}',
                  color: AppColors.cyan,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const SectionTitle(
            eyebrow: 'Pipeline global',
            title: 'Distribucion por etapa',
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.stages.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final stage = store.stages[index];
                final stageItems =
                    active.where((item) => item.stageId == stage.id).toList();
                final stageTotal = stageItems.fold<double>(
                  0,
                  (sum, item) => sum + item.amount,
                );
                return ManagerStageSummaryCard(
                  stage: stage,
                  count: stageItems.length,
                  total: stageTotal,
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: SectionTitle(
                  eyebrow: 'Equipo',
                  title: 'Cartera por vendedor',
                ),
              ),
              CountPill(value: '${team.length}'),
            ],
          ),
          const SizedBox(height: 10),
          for (final seller in rankedTeam.take(5))
            ManagerSellerPulse(
              seller: seller,
              opportunities:
                  active.where((item) => item.ownerId == seller.id).toList(),
              maxAmount: total,
            ),
          if (active.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionTitle(
              eyebrow: 'Atencion inmediata',
              title: 'Oportunidades prioritarias',
            ),
            const SizedBox(height: 10),
            for (final opportunity in ([...active]..sort((a, b) {
                    final overdueOrder = (_isOverdueOpportunity(b) ? 1 : 0)
                        .compareTo(_isOverdueOpportunity(a) ? 1 : 0);
                    if (overdueOrder != 0) return overdueOrder;
                    return b.amount.compareTo(a.amount);
                  }))
                .take(4))
              MiniOpportunityTile(
                opportunity: opportunity,
                onTap: () => onOpenOpportunity(opportunity.id),
              ),
          ],
        ],
      ),
    );
  }
}

class ManagerHeroCard extends StatelessWidget {
  const ManagerHeroCard({
    required this.crmTotal,
    required this.managerialTotal,
    required this.managerialOpportunityCount,
    required this.crmOpportunityCount,
    required this.sellerCount,
    required this.onAssignOpportunity,
    required this.onSync,
    super.key,
  });

  final double crmTotal;
  final double managerialTotal;
  final int managerialOpportunityCount;
  final int crmOpportunityCount;
  final int sellerCount;
  final VoidCallback onAssignOpportunity;
  final Future<void> Function() onSync;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.green.withValues(alpha: 0.2),
            AppColors.surface.withValues(alpha: 0.96),
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.34)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x3300D7B1),
            blurRadius: 34,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.insights_rounded,
                  color: AppColors.green,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'OPORTUNIDADES GERENCIALES',
                  style: TextStyle(
                    color: AppColors.green,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Actualizar',
                onPressed: () => unawaited(onSync()),
                icon: const Icon(Icons.sync_rounded),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _currency(managerialTotal),
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 36,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.4,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$managerialOpportunityCount oportunidades gerenciales',
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'TOTAL CRM DE VENDEDORES',
            style: TextStyle(
              color: AppColors.green,
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _currency(crmTotal),
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '$crmOpportunityCount oportunidades activas · $sellerCount vendedores',
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onAssignOpportunity,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Asignar oportunidad'),
            ),
          ),
        ],
      ),
    );
  }
}

class ManagerMetricCard extends StatelessWidget {
  const ManagerMetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          Text(label, style: const TextStyle(color: AppColors.muted)),
        ],
      ),
    );
  }
}

class ManagerStageSummaryCard extends StatelessWidget {
  const ManagerStageSummaryCard({
    required this.stage,
    required this.count,
    required this.total,
    super.key,
  });

  final SalesStage stage;
  final int count;
  final double total;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 178,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ETAPA ${stage.id}',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
              ),
              CountPill(value: '$count'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stage.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const Spacer(),
          Text(
            _currency(total),
            style: const TextStyle(
              color: AppColors.green,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class ManagerSellerPulse extends StatelessWidget {
  const ManagerSellerPulse({
    required this.seller,
    required this.opportunities,
    required this.maxAmount,
    super.key,
  });

  final SalesUser seller;
  final List<Opportunity> opportunities;
  final double maxAmount;

  @override
  Widget build(BuildContext context) {
    final total = opportunities.fold<double>(
      0,
      (sum, item) => sum + item.amount,
    );
    final progress = maxAmount <= 0 ? 0.0 : (total / maxAmount).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GlassCard(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            InitialsAvatar(initials: seller.initials, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    seller.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: AppColors.line,
                      color: AppColors.green,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _currency(total),
                  style: const TextStyle(
                    color: AppColors.green,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${opportunities.length} activas',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ManagerTeamPage extends StatefulWidget {
  const ManagerTeamPage({
    required this.store,
    required this.onAssignOpportunity,
    required this.onOpenOpportunity,
    super.key,
  });

  final SalesStore store;
  final void Function(SalesUser?) onAssignOpportunity;
  final ValueChanged<String> onOpenOpportunity;

  @override
  State<ManagerTeamPage> createState() => _ManagerTeamPageState();
}

class _ManagerTeamPageState extends State<ManagerTeamPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final sellers = widget.store.sellers
        .where(
          (item) =>
              item.roleId == 'sales_exec' &&
              (query.isEmpty ||
                  '${item.name} ${item.email}'.toLowerCase().contains(
                        query.toLowerCase(),
                      )),
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        Row(
          children: [
            const Expanded(
              child: SectionTitle(
                eyebrow: 'Administracion comercial',
                title: 'Equipo de ventas',
              ),
            ),
            IconButton.filled(
              tooltip: 'Asignar oportunidad',
              onPressed: () => widget.onAssignOpportunity(null),
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          onChanged: (value) => setState(() => query = value),
          decoration: const InputDecoration(
            labelText: 'Buscar vendedor',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 14),
        for (final seller in sellers)
          ManagerTeamSellerCard(
            seller: seller,
            opportunities: widget.store.opportunities
                .where((item) => item.ownerId == seller.id)
                .toList(),
            onAssign: () => widget.onAssignOpportunity(seller),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (context) => ManagerSellerDetailSheet(
                seller: seller,
                opportunities: widget.store.opportunities
                    .where((item) => item.ownerId == seller.id)
                    .toList(),
                onAssign: () {
                  Navigator.pop(context);
                  widget.onAssignOpportunity(seller);
                },
                onOpenOpportunity: (id) {
                  Navigator.pop(context);
                  widget.onOpenOpportunity(id);
                },
              ),
            ),
          ),
        if (sellers.isEmpty)
          const EmptyBlock(text: 'No hay vendedores con este criterio.'),
      ],
    );
  }
}

class ManagerTeamSellerCard extends StatelessWidget {
  const ManagerTeamSellerCard({
    required this.seller,
    required this.opportunities,
    required this.onAssign,
    required this.onTap,
    super.key,
  });

  final SalesUser seller;
  final List<Opportunity> opportunities;
  final VoidCallback onAssign;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = opportunities.where(_isActiveOpportunity).toList();
    final total = active.fold<double>(0, (sum, item) => sum + item.amount);
    final overdue = active.where(_isOverdueOpportunity).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: GlassCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            children: [
              Row(
                children: [
                  InitialsAvatar(initials: seller.initials, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          seller.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          seller.email.isEmpty
                              ? seller.territory
                              : seller.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Asignar oportunidad',
                    onPressed: onAssign,
                    icon: const Icon(
                      Icons.add_business_outlined,
                      color: AppColors.green,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  Expanded(
                    child: _ManagerInlineMetric(
                      label: 'Cartera activa',
                      value: _currency(total),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ManagerInlineMetric(
                      label: 'Oportunidades',
                      value: '${active.length}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ManagerInlineMetric(
                      label: 'Vencidas',
                      value: '$overdue',
                      alert: overdue > 0,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagerInlineMetric extends StatelessWidget {
  const _ManagerInlineMetric({
    required this.label,
    required this.value,
    this.alert = false,
  });

  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: TextStyle(
                color: alert ? AppColors.red : AppColors.ink,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

class ManagerPipelinePage extends StatelessWidget {
  const ManagerPipelinePage({
    required this.store,
    required this.onOpenOpportunity,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<String> onOpenOpportunity;

  @override
  Widget build(BuildContext context) {
    final active = store.opportunities.where(_isActiveOpportunity).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        const SectionTitle(
          eyebrow: 'Pipeline global',
          title: 'Oportunidades del equipo',
        ),
        const SizedBox(height: 10),
        for (final stage in store.stages)
          StageLane(
            stage: stage,
            opportunities:
                active.where((item) => item.stageId == stage.id).toList(),
            onOpenOpportunity: onOpenOpportunity,
          ),
      ],
    );
  }
}

class ManagerSellerDetailSheet extends StatelessWidget {
  const ManagerSellerDetailSheet({
    required this.seller,
    required this.opportunities,
    required this.onAssign,
    required this.onOpenOpportunity,
    super.key,
  });

  final SalesUser seller;
  final List<Opportunity> opportunities;
  final VoidCallback onAssign;
  final ValueChanged<String> onOpenOpportunity;

  @override
  Widget build(BuildContext context) {
    final active = opportunities.where(_isActiveOpportunity).toList();
    final total = active.fold<double>(0, (sum, item) => sum + item.amount);
    return SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(initials: seller.initials, size: 50),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      seller.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${active.length} activas · ${_currency(total)}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onAssign,
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Asignar nueva oportunidad'),
            ),
          ),
          const SizedBox(height: 16),
          if (active.isEmpty)
            const EmptyBlock(text: 'Este vendedor no tiene cartera activa.')
          else
            for (final opportunity in active)
              MiniOpportunityTile(
                opportunity: opportunity,
                onTap: () => onOpenOpportunity(opportunity.id),
              ),
        ],
      ),
    );
  }
}

class ManagerSellerPickerSheet extends StatelessWidget {
  const ManagerSellerPickerSheet({
    required this.store,
    required this.onSelected,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<SalesUser> onSelected;

  @override
  Widget build(BuildContext context) {
    final sellers =
        store.sellers.where((item) => item.roleId == 'sales_exec').toList();
    return SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.person_search_outlined, color: AppColors.green),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Seleccionar vendedor',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            'La oportunidad aparecera en su cartera y activara una notificacion.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          for (final seller in sellers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => onSelected(seller),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.line),
                ),
                tileColor: Colors.white.withValues(alpha: 0.04),
                leading: InitialsAvatar(initials: seller.initials, size: 40),
                title: Text(
                  seller.name,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  seller.email.isEmpty ? seller.territory : seller.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ),
        ],
      ),
    );
  }
}

class ManagerProfileSheet extends StatelessWidget {
  const ManagerProfileSheet({
    required this.user,
    required this.onLogout,
    super.key,
  });

  final SalesUser user;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Column(
        children: [
          InitialsAvatar(initials: user.initials, size: 58),
          const SizedBox(height: 12),
          Text(
            user.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          const Text(
            'Administracion comercial',
            style: TextStyle(color: AppColors.green),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout_outlined),
              label: const Text('Cerrar sesion'),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isActiveOpportunity(Opportunity item) =>
    !{'ganada', 'perdida', 'cancelada'}.contains(item.status.toLowerCase());

bool _isOverdueOpportunity(Opportunity item) {
  if (!_isActiveOpportunity(item) || item.deadline.isEmpty) return false;
  final deadline = DateTime.tryParse(item.deadline);
  if (deadline == null) return false;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return deadline.isBefore(today);
}

class SellerRegistrationPage extends StatefulWidget {
  const SellerRegistrationPage({
    required this.store,
    required this.onRegister,
    required this.onLogin,
    required this.onCreateSeller,
    required this.onRetry,
    this.offlineReason,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<SalesUser> onRegister;
  final Future<void> Function(LoginDraft draft) onLogin;
  final Future<void> Function(SellerDraft draft) onCreateSeller;
  final VoidCallback onRetry;
  final String? offlineReason;

  @override
  State<SellerRegistrationPage> createState() => _SellerRegistrationPageState();
}

class _SellerRegistrationPageState extends State<SellerRegistrationPage>
    with TickerProviderStateMixin {
  final loginUserController = TextEditingController();
  final loginPasswordController = TextEditingController();
  final firstNameController = TextEditingController();
  final lastNameController = TextEditingController();
  final duiController = TextEditingController();
  final addressController = TextEditingController();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  bool saving = false;
  bool registerMode = false;
  bool showLoginPassword = false;
  bool showRegisterPassword = false;
  bool showConfirmPassword = false;
  late final AnimationController introController;
  late final AnimationController ambientController;
  late final Animation<double> introFade;
  late final Animation<Offset> introSlide;

  @override
  void dispose() {
    introController.dispose();
    ambientController.dispose();
    loginUserController.dispose();
    loginPasswordController.dispose();
    firstNameController.dispose();
    lastNameController.dispose();
    duiController.dispose();
    addressController.dispose();
    phoneController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    )..forward();
    ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();
    introFade = CurvedAnimation(
      parent: introController,
      curve: const Interval(0, 0.82, curve: Curves.easeOutCubic),
    );
    introSlide =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(parent: introController, curve: Curves.easeOutCubic),
    );
    firstNameController.addListener(() => setState(() {}));
    lastNameController.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 60),
          child: Center(
            child: FadeTransition(
              opacity: introFade,
              child: SlideTransition(
                position: introSlide,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: ambientController,
                        builder: (context, child) {
                          final phase = ambientController.value * math.pi * 2;
                          return Transform.translate(
                            offset: Offset(0, math.sin(phase) * 4),
                            child: Transform.scale(
                              scale: 1 + math.sin(phase) * 0.012,
                              child: child,
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(30),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.green.withValues(alpha: 0.2),
                                blurRadius: 46,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const KmiLogoMark(width: 138, height: 86),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _AuthGlassSurface(
                        child: Theme(
                          data: Theme.of(
                            context,
                          ).copyWith(inputDecorationTheme: _authInputTheme()),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 360),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween<double>(
                                  begin: 0.975,
                                  end: 1,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: KeyedSubtree(
                              key: ValueKey(registerMode),
                              child: registerMode
                                  ? buildRegisterForm()
                                  : buildLoginForm(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () =>
                                setState(() => registerMode = !registerMode),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.green,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                        child: Text(
                          registerMode
                              ? 'Ya tengo usuario · Iniciar sesión'
                              : '¿No tienes usuario? · Regístrate',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (widget.offlineReason != null) ...[
                        const SizedBox(height: 10),
                        OfflineBanner(
                          message: widget.offlineReason!,
                          onRetry: widget.onRetry,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecorationTheme _authInputTheme() {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.line),
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.055),
      labelStyle: const TextStyle(
        color: AppColors.muted,
        fontWeight: FontWeight.w700,
      ),
      prefixIconColor: AppColors.green,
      suffixIconColor: AppColors.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: AppColors.green, width: 1.5),
      ),
    );
  }

  Widget buildLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: loginUserController,
          decoration: const InputDecoration(
            labelText: 'Usuario',
            prefixIcon: Icon(Icons.person_outline),
          ),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: loginPasswordController,
          decoration: InputDecoration(
            labelText: 'Contraseña',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: showLoginPassword ? 'Ocultar' : 'Mostrar',
              onPressed: () =>
                  setState(() => showLoginPassword = !showLoginPassword),
              icon: Icon(
                showLoginPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          obscureText: !showLoginPassword,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: saving ? null : submitLogin,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: AppColors.green,
            foregroundColor: AppColors.page,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          icon: saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: const Text('Ingresar'),
        ),
      ],
    );
  }

  Widget buildRegisterForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Crear usuario',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: firstNameController,
          decoration: const InputDecoration(
            labelText: 'Nombres',
            prefixIcon: Icon(Icons.person_outline),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: lastNameController,
          decoration: const InputDecoration(
            labelText: 'Apellidos',
            prefixIcon: Icon(Icons.person_outline),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: duiController,
          decoration: const InputDecoration(
            labelText: 'DUI',
            prefixIcon: Icon(Icons.credit_card_outlined),
          ),
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: addressController,
          decoration: const InputDecoration(
            labelText: 'Direccion',
            prefixIcon: Icon(Icons.home_outlined),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: phoneController,
          decoration: const InputDecoration(
            labelText: 'Telefono',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: emailController,
          decoration: const InputDecoration(
            labelText: 'Correo / usuario',
            prefixIcon: Icon(Icons.mail_outline),
          ),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: passwordController,
          decoration: InputDecoration(
            labelText: 'Contraseña',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: showRegisterPassword ? 'Ocultar' : 'Mostrar',
              onPressed: () =>
                  setState(() => showRegisterPassword = !showRegisterPassword),
              icon: Icon(
                showRegisterPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          obscureText: !showRegisterPassword,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: confirmPasswordController,
          decoration: InputDecoration(
            labelText: 'Confirmar contraseña',
            prefixIcon: const Icon(Icons.lock_reset_outlined),
            suffixIcon: IconButton(
              tooltip: showConfirmPassword ? 'Ocultar' : 'Mostrar',
              onPressed: () =>
                  setState(() => showConfirmPassword = !showConfirmPassword),
              icon: Icon(
                showConfirmPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          obscureText: !showConfirmPassword,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: saving ? null : submitRegistration,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: AppColors.green,
            foregroundColor: AppColors.page,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
          icon: saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_add_alt_1_outlined),
          label: const Text('Registrarme y entrar'),
        ),
      ],
    );
  }

  Future<void> submitLogin() async {
    final username = loginUserController.text.trim();
    final password = loginPasswordController.text.trim();
    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa usuario y contrasena.')),
      );
      return;
    }

    setState(() => saving = true);
    await widget.onLogin(LoginDraft(username: username, password: password));
    if (mounted) setState(() => saving = false);
  }

  Future<void> submitRegistration() async {
    final firstName = firstNameController.text.trim();
    final lastName = lastNameController.text.trim();
    final dui = duiController.text.trim();
    final address = addressController.text.trim();
    final phone = phoneController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text.trim();
    final confirmPassword = confirmPasswordController.text.trim();
    if (firstName.isEmpty || lastName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa nombres y apellidos.')),
      );
      return;
    }
    if (!_validDui(dui)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El DUI debe tener 8 o 9 digitos.')),
      );
      return;
    }
    if (address.isEmpty || !_validPhone(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa direccion y telefono valido.')),
      );
      return;
    }
    if (!_validEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa un correo valido.')),
      );
      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La contrasena debe tener 6 caracteres.')),
      );
      return;
    }
    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Las contrasenas no coinciden.')),
      );
      return;
    }

    setState(() => saving = true);
    await widget.onCreateSeller(
      SellerDraft(
        firstName: firstName,
        lastName: lastName,
        dui: dui,
        address: address,
        phone: phone,
        email: email,
        password: password,
      ),
    );
    if (mounted) setState(() => saving = false);
  }

  bool _validEmail(String value) {
    final parts = value.split('@');
    return parts.length == 2 && parts.last.contains('.');
  }

  bool _validPhone(String value) {
    return value.replaceAll(RegExp(r'\D'), '').length >= 8;
  }

  bool _validDui(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length == 8 || digits.length == 9;
  }
}

class _AuthGlassSurface extends StatelessWidget {
  const _AuthGlassSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.09),
                AppColors.surface.withValues(alpha: 0.76),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x5C020817),
                blurRadius: 46,
                offset: Offset(0, 24),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class SessionMetric extends StatelessWidget {
  const SessionMetric({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: AppColors.muted)),
        ],
      ),
    );
  }
}

class DarkBackdrop extends StatelessWidget {
  const DarkBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111A2D), Color(0xFF17233A), Color(0xFF10271F)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -80,
            left: -40,
            child: Glow(
              color: AppColors.green.withValues(alpha: 0.22),
              size: 220,
            ),
          ),
          Positioned(
            top: 80,
            right: -70,
            child: Glow(
              color: AppColors.cyan.withValues(alpha: 0.18),
              size: 240,
            ),
          ),
          Positioned(
            bottom: -90,
            right: 30,
            child: Glow(
              color: AppColors.yellow.withValues(alpha: 0.12),
              size: 260,
            ),
          ),
        ],
      ),
    );
  }
}

class Glow extends StatelessWidget {
  const Glow({required this.color, required this.size, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.seller,
    required this.managerMode,
    required this.onNewOpportunity,
    required this.onOpenProfile,
    super.key,
  });

  final SalesUser seller;
  final bool managerMode;
  final VoidCallback onNewOpportunity;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final firstName = seller.name.trim().split(RegExp(r'\s+')).first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: SizedBox(
        height: 70,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Mi perfil',
                onPressed: onOpenProfile,
                icon: const Icon(Icons.account_circle_outlined),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const KmiLogoMark(width: 78, height: 42),
                const SizedBox(height: 2),
                Text(
                  firstName,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .2,
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton.filledTonal(
                tooltip:
                    managerMode ? 'Asignar oportunidad' : 'Nueva oportunidad',
                onPressed: onNewOpportunity,
                icon: Icon(
                  managerMode
                      ? Icons.person_add_alt_1_outlined
                      : Icons.add_business_outlined,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class KmiLogoMark extends StatelessWidget {
  const KmiLogoMark({required this.width, required this.height, super.key});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Image.asset(
        'assets/kmi-logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        semanticLabel: 'KMI',
      ),
    );
  }
}

class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({required this.initials, this.size = 48, super.key});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const LinearGradient(
          colors: [AppColors.yellow, AppColors.green],
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: const Color(0xFF06100F),
            fontWeight: FontWeight.w900,
            fontSize: size >= 56 ? 18 : 15,
          ),
        ),
      ),
    );
  }
}

class OpportunitiesPage extends StatefulWidget {
  const OpportunitiesPage({
    required this.store,
    required this.unreadOpportunityIds,
    required this.onMarkAssignmentsRead,
    required this.onNewOpportunity,
    required this.onOpenOpportunity,
    required this.onEditOpportunity,
    required this.onSync,
    super.key,
  });

  final SalesStore store;
  final Set<String> unreadOpportunityIds;
  final VoidCallback onMarkAssignmentsRead;
  final VoidCallback onNewOpportunity;
  final ValueChanged<String> onOpenOpportunity;
  final ValueChanged<Opportunity> onEditOpportunity;
  final Future<void> Function() onSync;

  @override
  State<OpportunitiesPage> createState() => _OpportunitiesPageState();
}

class _OpportunitiesPageState extends State<OpportunitiesPage> {
  int? selectedStageId;

  @override
  Widget build(BuildContext context) {
    final opportunities = widget.store.myActiveOpportunities;
    final stages = [...widget.store.stages]
      ..sort((a, b) => a.id.compareTo(b.id));
    final total = opportunities.fold<double>(
      0,
      (sum, opportunity) => sum + opportunity.amount,
    );
    final visibleOpportunities = opportunities
        .where(
          (opportunity) =>
              selectedStageId == null || opportunity.stageId == selectedStageId,
        )
        .toList()
      ..sort((a, b) {
        final stageOrder = a.stageId.compareTo(b.stageId);
        return stageOrder != 0 ? stageOrder : a.deadline.compareTo(b.deadline);
      });
    SalesStage? selectedStage;
    for (final stage in stages) {
      if (stage.id == selectedStageId) selectedStage = stage;
    }

    return RefreshIndicator(
      onRefresh: widget.onSync,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        children: [
          ActivePipelineHero(
            amount: total,
            opportunityCount: opportunities.length,
            unreadCount: widget.unreadOpportunityIds.length,
            onNotifications: () => showCrmAssignmentNotifications(
              context,
              widget.store,
              opportunities,
            ),
            onSync: () => unawaited(widget.onSync()),
            onNewOpportunity: widget.onNewOpportunity,
          ),
          const SizedBox(height: 18),
          const Text(
            'ETAPAS DE VENTA',
            style: TextStyle(
              color: AppColors.green,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Explora tu pipeline',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: stages.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final stage = index == 0 ? null : stages[index - 1];
                final stageOpportunities = stage == null
                    ? opportunities
                    : opportunities
                        .where((item) => item.stageId == stage.id)
                        .toList();
                final stageTotal = stageOpportunities.fold<double>(
                  0,
                  (sum, opportunity) => sum + opportunity.amount,
                );
                return PipelineStageCarouselCard(
                  stageNumber: stage?.id,
                  title: stage?.name ?? 'Todas',
                  count: stageOpportunities.length,
                  amount: stageTotal,
                  selected: selectedStageId == stage?.id,
                  onTap: () => setState(() => selectedStageId = stage?.id),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selectedStage?.name ?? 'Todas las oportunidades',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${visibleOpportunities.length} en esta vista',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              CountPill(value: '${visibleOpportunities.length}'),
            ],
          ),
          const SizedBox(height: 12),
          if (visibleOpportunities.isEmpty)
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  EmptyBlock(
                    text: selectedStage == null
                        ? 'Aun no tienes oportunidades vigentes asignadas desde CRM.'
                        : 'No hay oportunidades activas en ${selectedStage.name}.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(widget.onSync()),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sincronizar asignaciones CRM'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: widget.onNewOpportunity,
                      icon: const Icon(Icons.add_business_outlined),
                      label: const Text('Crear primera oportunidad'),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final opportunity in visibleOpportunities)
              OpportunityListCard(
                opportunity: opportunity,
                onTap: () => widget.onOpenOpportunity(opportunity.id),
                onEdit: () => widget.onEditOpportunity(opportunity),
              ),
        ],
      ),
    );
  }

  void showCrmAssignmentNotifications(
    BuildContext context,
    SalesStore store,
    List<Opportunity> opportunities,
  ) {
    final notifications = opportunities
        .where((item) => widget.unreadOpportunityIds.contains(item.id))
        .toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SheetShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Notificaciones CRM',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'Cartera asignada a ${store.currentSeller.name}',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            if (notifications.isEmpty)
              const EmptyBlock(
                text: 'No hay nuevas oportunidades asignadas desde CRM.',
              )
            else
              for (final opportunity in notifications.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.assignment_turned_in_outlined,
                          color: AppColors.green,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opportunity.company,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                '${opportunity.amountLabel} - Etapa ${opportunity.stageId}',
                                style: const TextStyle(color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            if (notifications.length > 6)
              Text(
                '+${notifications.length - 6} oportunidades adicionales',
                style: const TextStyle(color: AppColors.muted),
              ),
          ],
        ),
      ),
    );
    widget.onMarkAssignmentsRead();
  }
}

class ActivePipelineHero extends StatelessWidget {
  const ActivePipelineHero({
    required this.amount,
    required this.opportunityCount,
    required this.unreadCount,
    required this.onNotifications,
    required this.onSync,
    required this.onNewOpportunity,
    super.key,
  });

  final double amount;
  final int opportunityCount;
  final int unreadCount;
  final VoidCallback onNotifications;
  final VoidCallback onSync;
  final VoidCallback onNewOpportunity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF244557), Color(0xFF17233A)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.green.withValues(alpha: .25)),
        boxShadow: [
          BoxShadow(
            color: AppColors.green.withValues(alpha: .08),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.trending_up_rounded,
                  color: AppColors.green,
                  size: 21,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'OPORTUNIDADES ACTIVAS',
                  style: TextStyle(
                    color: AppColors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Sincronizar CRM',
                visualDensity: VisualDensity.compact,
                onPressed: onSync,
                icon: const Icon(Icons.sync_rounded, size: 21),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _currency(amount),
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 36,
              height: 1,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$opportunityCount oportunidades vigentes',
            style: const TextStyle(
              color: AppColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Badge.count(
                count: unreadCount,
                isLabelVisible: unreadCount > 0,
                backgroundColor: AppColors.red,
                child: IconButton.outlined(
                  tooltip: 'Asignaciones CRM',
                  onPressed: onNotifications,
                  icon: Icon(
                    unreadCount > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    size: 21,
                  ),
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: onNewOpportunity,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Nueva'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PipelineStageCarouselCard extends StatelessWidget {
  const PipelineStageCarouselCard({
    required this.stageNumber,
    required this.title,
    required this.count,
    required this.amount,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final int? stageNumber;
  final String title;
  final int count;
  final double amount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $count oportunidades, ${_currency(amount)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          width: 164,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.green, Color(0xFF5EDFC8)],
                  )
                : null,
            color: selected ? null : AppColors.panel,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? AppColors.green : AppColors.line,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.green.withValues(alpha: .18),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    stageNumber == null ? 'PIPELINE' : 'ETAPA ${stageNumber!}',
                    style: TextStyle(
                      color: selected
                          ? AppColors.page.withValues(alpha: .7)
                          : AppColors.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .8,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.page.withValues(alpha: .12)
                          : AppColors.green.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: selected ? AppColors.page : AppColors.green,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.page : AppColors.ink,
                  fontSize: 14,
                  height: 1.12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                _currency(amount),
                style: TextStyle(
                  color: selected ? AppColors.page : AppColors.green,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OpportunityListCard extends StatelessWidget {
  const OpportunityListCard({
    required this.opportunity,
    required this.onTap,
    required this.onEdit,
    super.key,
  });

  final Opportunity opportunity;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 4,
                  height: 68,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.green, AppColors.cyan],
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              opportunity.company,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            opportunity.amountLabel,
                            style: const TextStyle(
                              color: AppColors.green,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        opportunity.product.isEmpty
                            ? 'Producto pendiente'
                            : opportunity.product,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Flexible(
                            child: CompactOpportunityMeta(
                              icon: Icons.route_outlined,
                              text: opportunity.stageName,
                              highlighted: true,
                            ),
                          ),
                          const SizedBox(width: 7),
                          CompactOpportunityMeta(
                            icon: Icons.percent_rounded,
                            text: '${opportunity.closePercent}',
                          ),
                          const SizedBox(width: 7),
                          CompactOpportunityMeta(
                            icon: Icons.event_outlined,
                            text: opportunity.deadlineLabel,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Editar oportunidad',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CompactOpportunityMeta extends StatelessWidget {
  const CompactOpportunityMeta({
    required this.icon,
    required this.text,
    this.highlighted = false,
    super.key,
  });

  final IconData icon;
  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppColors.green : AppColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: highlighted ? .1 : .06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

class AgendaPage extends StatefulWidget {
  const AgendaPage({
    required this.store,
    required this.onStatusChange,
    required this.onOpenOpportunity,
    required this.onCaptureForm,
    required this.onNewGestion,
    super.key,
  });

  final SalesStore store;
  final Future<void> Function(String agendaId, VisitStatus status)
      onStatusChange;
  final ValueChanged<String> onOpenOpportunity;
  final ValueChanged<int> onCaptureForm;
  final VoidCallback onNewGestion;

  @override
  State<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends State<AgendaPage> {
  String filter = 'Hoy';
  String? selectedDate;

  @override
  Widget build(BuildContext context) {
    final items = selectedDate == null
        ? widget.store.filteredAgenda(filter)
        : widget.store.agendaForDate(selectedDate!);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        SummaryPanel(store: widget.store),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilterBar(
                selected: filter,
                values: const ['Hoy'],
                onChanged: (value) => setState(() {
                  filter = value;
                  selectedDate = null;
                }),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              tooltip: 'Filtrar fecha exacta',
              onPressed: pickExactDate,
              style: IconButton.styleFrom(
                backgroundColor:
                    selectedDate == null ? AppColors.green : AppColors.cyan,
              ),
              icon: const Icon(Icons.calendar_month_outlined),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SectionTitle(
          eyebrow: 'Bitacora por hora',
          title: selectedDate == null
              ? 'Agenda AM / PM'
              : 'Agenda ${_displayDate(selectedDate!)}',
        ),
        const SizedBox(height: 10),
        AgendaTimeline(
          items: items,
          store: widget.store,
          onOpenOpportunity: widget.onOpenOpportunity,
          onStatusChange: widget.onStatusChange,
          onCaptureForm: widget.onCaptureForm,
        ),
      ],
    );
  }

  Future<void> pickExactDate() async {
    final initialDate = _parseIsoDate(selectedDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2025),
      lastDate: DateTime(2030),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: AppColors.green,
                surface: AppColors.surface,
              ),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      selectedDate = _isoDate(picked);
    });
  }

  static DateTime? _parseIsoDate(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static String _isoDate(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  static String _displayDate(String value) {
    final parsed = _parseIsoDate(value);
    if (parsed == null) return value;
    return '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
  }
}

class SummaryPanel extends StatelessWidget {
  const SummaryPanel({required this.store, super.key});

  final SalesStore store;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: SummaryMetric(
              label: 'Visitas',
              value: '${store.myAgenda.length}',
            ),
          ),
          Expanded(
            child: SummaryMetric(
              label: 'En campo',
              value: '${store.inVisitCount}',
            ),
          ),
          Expanded(
            child: SummaryMetric(label: 'Pipeline', value: store.pipelineLabel),
          ),
        ],
      ),
    );
  }
}

class SummaryMetric extends StatelessWidget {
  const SummaryMetric({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: AppColors.muted)),
      ],
    );
  }
}

class FilterBar extends StatelessWidget {
  const FilterBar({
    required this.selected,
    required this.values,
    required this.onChanged,
    super.key,
  });

  final String selected;
  final List<String> values;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: TextButton(
                onPressed: () => onChanged(value),
                style: TextButton.styleFrom(
                  foregroundColor: selected == value
                      ? const Color(0xFF04100F)
                      : AppColors.muted,
                  backgroundColor:
                      selected == value ? AppColors.green : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AgendaTimeline extends StatelessWidget {
  const AgendaTimeline({
    required this.items,
    required this.store,
    required this.onOpenOpportunity,
    required this.onStatusChange,
    required this.onCaptureForm,
    super.key,
  });

  final List<AgendaItem> items;
  final SalesStore store;
  final ValueChanged<String> onOpenOpportunity;
  final Future<void> Function(String agendaId, VisitStatus status)
      onStatusChange;
  final ValueChanged<int> onCaptureForm;

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]
      ..sort((a, b) => '${a.date} ${a.time}'.compareTo('${b.date} ${b.time}'));
    const slots = [
      '08:00',
      '09:00',
      '10:00',
      '11:00',
      '12:00',
      '13:00',
      '14:00',
      '15:00',
      '16:00',
      '17:00',
    ];
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _DayPartLabel(text: 'AM'),
          for (final slot in slots.take(4))
            _ScheduleRow(
              slot: slot,
              item: _itemForSlot(sorted, slot),
              opportunity: _opportunityForSlot(sorted, store, slot),
              onOpenOpportunity: onOpenOpportunity,
              onStatusChange: onStatusChange,
              onCaptureForm: onCaptureForm,
            ),
          const SizedBox(height: 4),
          const _DayPartLabel(text: 'PM'),
          for (final slot in slots.skip(4))
            _ScheduleRow(
              slot: slot,
              item: _itemForSlot(sorted, slot),
              opportunity: _opportunityForSlot(sorted, store, slot),
              onOpenOpportunity: onOpenOpportunity,
              onStatusChange: onStatusChange,
              onCaptureForm: onCaptureForm,
            ),
          for (final item in _itemsOutsideSlots(sorted, slots))
            _ScheduleRow(
              slot: item.time,
              item: item,
              opportunity: store.opportunityById(item.opportunityId),
              onOpenOpportunity: onOpenOpportunity,
              onStatusChange: onStatusChange,
              onCaptureForm: onCaptureForm,
            ),
        ],
      ),
    );
  }

  static AgendaItem? _itemForSlot(List<AgendaItem> items, String slot) {
    for (final item in items) {
      if (_slotFor(item.time) == slot) return item;
    }
    return null;
  }

  static Opportunity? _opportunityForSlot(
    List<AgendaItem> items,
    SalesStore store,
    String slot,
  ) {
    final item = _itemForSlot(items, slot);
    return item == null ? null : store.opportunityById(item.opportunityId);
  }

  static List<AgendaItem> _itemsOutsideSlots(
    List<AgendaItem> items,
    List<String> slots,
  ) {
    return items.where((item) => !slots.contains(_slotFor(item.time))).toList();
  }

  static String _slotFor(String time) {
    final parts = time.split(':');
    final hour = int.tryParse(parts.first) ?? 9;
    return '${hour.toString().padLeft(2, '0')}:00';
  }
}

class _DayPartLabel extends StatelessWidget {
  const _DayPartLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(1, 4, 0, 5),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.green,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.slot,
    required this.item,
    required this.opportunity,
    required this.onOpenOpportunity,
    required this.onStatusChange,
    required this.onCaptureForm,
  });

  final String slot;
  final AgendaItem? item;
  final Opportunity? opportunity;
  final ValueChanged<String> onOpenOpportunity;
  final Future<void> Function(String agendaId, VisitStatus status)
      onStatusChange;
  final ValueChanged<int> onCaptureForm;

  @override
  Widget build(BuildContext context) {
    final scheduledItem = item;
    final scheduledOpportunity = opportunity;
    final hasTask = scheduledItem != null && scheduledOpportunity != null;
    final accent = hasTask ? _accentFor(scheduledItem.type) : AppColors.line;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 54,
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  slot,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _endTime(slot),
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: hasTask
                  ? () => onOpenOpportunity(scheduledItem.opportunityId)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                constraints: const BoxConstraints(minHeight: 61),
                decoration: BoxDecoration(
                  color: hasTask
                      ? Colors.white.withValues(alpha: 0.055)
                      : Colors.white.withValues(alpha: 0.025),
                  border: Border.all(
                    color: hasTask
                        ? AppColors.line
                        : AppColors.line.withValues(alpha: 0.55),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      Container(
                        width: 5,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(8),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                          child: hasTask
                              ? _TaskContent(
                                  item: scheduledItem,
                                  opportunity: scheduledOpportunity,
                                  onStatusChange: onStatusChange,
                                  onCaptureForm: onCaptureForm,
                                )
                              : const _EmptySlotContent(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Color _accentFor(String type) {
    final normalized = type.toLowerCase();
    if (normalized.contains('llamada')) return AppColors.cyan;
    if (normalized.contains('whatsapp')) return AppColors.green;
    if (normalized.contains('correo')) return AppColors.yellow;
    return AppColors.red;
  }

  static String _endTime(String time) {
    final parts = time.split(':');
    final hour = int.tryParse(parts.first) ?? 9;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final end = DateTime(
      2026,
      1,
      1,
      hour,
      minute,
    ).add(const Duration(minutes: 45));
    return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  }
}

class _TaskContent extends StatelessWidget {
  const _TaskContent({
    required this.item,
    required this.opportunity,
    required this.onStatusChange,
    required this.onCaptureForm,
  });

  final AgendaItem item;
  final Opportunity opportunity;
  final Future<void> Function(String agendaId, VisitStatus status)
      onStatusChange;
  final ValueChanged<int> onCaptureForm;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                opportunity.company,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Acciones',
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (value) {
                if (value == 'check') {
                  unawaited(onStatusChange(item.id, VisitStatus.inVisit));
                }
                if (value == 'done') {
                  unawaited(onStatusChange(item.id, VisitStatus.done));
                }
                if (value == 'form') onCaptureForm(opportunity.stageId);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'check', child: Text('Check-in')),
                PopupMenuItem(value: 'done', child: Text('Realizada')),
                PopupMenuItem(value: 'form', child: Text('Formulario')),
              ],
            ),
          ],
        ),
        Text(
          '${item.time} - ${item.type}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.green, fontSize: 12),
        ),
        Text(
          item.place,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _EmptySlotContent extends StatelessWidget {
  const _EmptySlotContent();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(Icons.more_horiz, color: AppColors.muted, size: 17),
        SizedBox(width: 8),
        Text(
          'Disponible',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class AgendaCard extends StatelessWidget {
  const AgendaCard({
    required this.item,
    required this.opportunity,
    required this.onTap,
    required this.onCheckIn,
    required this.onComplete,
    required this.onCapture,
    super.key,
  });

  final AgendaItem item;
  final Opportunity opportunity;
  final VoidCallback onTap;
  final VoidCallback onCheckIn;
  final VoidCallback onComplete;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TimeBox(time: item.time),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          opportunity.company,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${item.type} - ${item.place}',
                          style: const TextStyle(color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  StatusChip(status: item.status),
                ],
              ),
              const SizedBox(height: 12),
              StageProgress(stageId: opportunity.stageId),
              const SizedBox(height: 10),
              Text(
                'Etapa ${opportunity.stageId}: ${opportunity.stageName}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                opportunity.nextAction,
                style: const TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onCheckIn,
                      icon: const Icon(Icons.location_on_outlined, size: 18),
                      label: const Text('Check-in'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onComplete,
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('Realizada'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Formulario',
                    onPressed: onCapture,
                    icon: const Icon(Icons.edit_note_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TimeBox extends StatelessWidget {
  const TimeBox({required this.time, super.key});

  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.18)),
      ),
      child: Center(
        child: Text(
          time,
          style: const TextStyle(
            color: AppColors.green,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class PipelinePage extends StatelessWidget {
  const PipelinePage({
    required this.store,
    required this.onOpenOpportunity,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<String> onOpenOpportunity;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        const SectionTitle(
          eyebrow: 'Pipeline personal',
          title: 'Oportunidades por etapa',
        ),
        const SizedBox(height: 10),
        for (final stage in store.stages)
          StageLane(
            stage: stage,
            opportunities: store.myOpportunities
                .where((item) => item.stageId == stage.id)
                .toList(),
            onOpenOpportunity: onOpenOpportunity,
          ),
      ],
    );
  }
}

class StageLane extends StatelessWidget {
  const StageLane({
    required this.stage,
    required this.opportunities,
    required this.onOpenOpportunity,
    super.key,
  });

  final SalesStage stage;
  final List<Opportunity> opportunities;
  final ValueChanged<String> onOpenOpportunity;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${stage.id}. ${stage.name}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                CountPill(value: '${opportunities.length}'),
              ],
            ),
            const SizedBox(height: 8),
            Text(stage.goal, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 12),
            if (opportunities.isEmpty)
              const EmptyBlock(text: 'Sin oportunidades en esta etapa')
            else
              for (final opportunity in opportunities)
                MiniOpportunityTile(
                  opportunity: opportunity,
                  onTap: () => onOpenOpportunity(opportunity.id),
                ),
          ],
        ),
      ),
    );
  }
}

class MiniOpportunityTile extends StatelessWidget {
  const MiniOpportunityTile({
    required this.opportunity,
    required this.onTap,
    super.key,
  });

  final Opportunity opportunity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    opportunity.company,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${opportunity.temperature} - ${opportunity.priority}',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            Text(
              opportunity.amountLabel,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

class FormsPage extends StatelessWidget {
  const FormsPage({
    required this.store,
    required this.onCaptureForm,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<int> onCaptureForm;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        const SectionTitle(
          eyebrow: 'Capturas por etapa',
          title: 'Formularios operativos',
        ),
        const SizedBox(height: 10),
        for (final form in store.forms)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    form.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Etapa ${form.stageId}',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final field in form.fields.take(5)) Tag(text: field),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => onCaptureForm(form.stageId),
                          icon: const Icon(Icons.edit_note_outlined),
                          label: const Text('Capturar'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CountPill(
                        value:
                            '${store.formResponses[form.id]?.length ?? 0} registros',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class KpiPage extends StatelessWidget {
  const KpiPage({required this.store, super.key});

  final SalesStore store;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      KpiMetric('Pipeline', store.pipelineLabel, 'Monto activo'),
      KpiMetric('Visitas', '${store.myAgenda.length}', 'Agenda asignada'),
      KpiMetric('En campo', '${store.inVisitCount}', 'Check-in activo'),
      KpiMetric('Realizadas', '${store.doneCount}', 'Completadas'),
      KpiMetric('Calientes', '${store.hotCount}', 'Alta prioridad'),
      KpiMetric('Formularios', '${store.totalResponses}', 'Capturas guardadas'),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        const SectionTitle(
          eyebrow: 'Indicadores personales',
          title: 'Rendimiento de campo',
        ),
        const SizedBox(height: 10),
        GridView.builder(
          itemCount: metrics.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.25,
          ),
          itemBuilder: (context, index) => KpiCard(metric: metrics[index]),
        ),
        const SizedBox(height: 14),
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Conversion por etapa',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              for (final stage in store.stages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 118,
                        child: Text(
                          stage.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: StageProgress(
                          stageId: store.myOpportunities
                              .where((item) => item.stageId == stage.id)
                              .length,
                          max: store.myOpportunities.length,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class KpiCard extends StatelessWidget {
  const KpiCard({required this.metric, super.key});

  final KpiMetric metric;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(metric.label, style: const TextStyle(color: AppColors.muted)),
          const Spacer(),
          Text(
            metric.value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(
            metric.hint,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class OpportunityActionSheet extends StatefulWidget {
  const OpportunityActionSheet({
    required this.store,
    required this.opportunity,
    required this.agenda,
    required this.onSaveGestion,
    required this.onStatusChange,
    required this.onCaptureForm,
    super.key,
  });

  final SalesStore store;
  final Opportunity opportunity;
  final AgendaItem? agenda;
  final Future<void> Function(OpportunityGestionDraft draft) onSaveGestion;
  final Future<void> Function(String agendaId, VisitStatus status)
      onStatusChange;
  final VoidCallback onCaptureForm;

  @override
  State<OpportunityActionSheet> createState() => _OpportunityActionSheetState();
}

class _OpportunityActionSheetState extends State<OpportunityActionSheet> {
  final commentController = TextEditingController();
  late final TextEditingController dateController;
  int selectedTab = 0;
  int managementStageId = 1;
  String closureResult = 'ganado';
  bool saving = false;

  @override
  void initState() {
    super.initState();
    dateController = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10),
    );
    managementStageId = widget.opportunity.stageId;
    closureResult = widget.opportunity.status.toLowerCase() == 'perdida'
        ? 'perdida'
        : 'ganado';
  }

  @override
  void dispose() {
    commentController.dispose();
    dateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opportunity = widget.opportunity;

    return SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            opportunity.company,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            '${opportunity.contact} - ${opportunity.phone}',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OpportunitySheetTabButton(
                    label: 'Resumen',
                    icon: Icons.dashboard_outlined,
                    selected: selectedTab == 0,
                    onTap: () => setState(() => selectedTab = 0),
                  ),
                ),
                Expanded(
                  child: OpportunitySheetTabButton(
                    label: 'Gestiones',
                    icon: Icons.history_rounded,
                    selected: selectedTab == 1,
                    onTap: () => setState(() => selectedTab = 1),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: selectedTab == 0
                ? _buildSummary(opportunity)
                : _buildManagements(),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(Opportunity opportunity) {
    return Column(
      key: const ValueKey('opportunity-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailTile(
          label: 'Etapa',
          value: '${opportunity.stageId}. ${opportunity.stageName}',
        ),
        DetailTile(label: 'Producto', value: opportunity.product),
        DetailTile(label: 'Venta probable', value: opportunity.amountLabel),
        DetailTile(label: '% cierre', value: '${opportunity.closePercent}%'),
        DetailTile(label: 'Estatus', value: opportunity.status),
        DetailTile(label: 'Fecha inicio', value: opportunity.startDate),
        DetailTile(label: 'Fecha limite', value: opportunity.deadlineLabel),
        DetailTile(label: 'Estrategia', value: opportunity.strategy),
        DetailTile(label: 'Comentario', value: opportunity.comment),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filled(
              tooltip: 'Check-in',
              onPressed: widget.agenda == null
                  ? null
                  : () => unawaited(
                        widget.onStatusChange(
                          widget.agenda!.id,
                          VisitStatus.inVisit,
                        ),
                      ),
              icon: const Icon(Icons.location_on_outlined),
            ),
            const SizedBox(width: 12),
            IconButton.outlined(
              tooltip: 'Marcar realizada',
              onPressed: widget.agenda == null
                  ? null
                  : () => unawaited(
                        widget.onStatusChange(
                          widget.agenda!.id,
                          VisitStatus.done,
                        ),
                      ),
              icon: const Icon(Icons.check_circle_outline),
            ),
            const SizedBox(width: 12),
            IconButton.outlined(
              tooltip: 'Capturar formulario de etapa',
              onPressed: widget.onCaptureForm,
              icon: const Icon(Icons.assignment_outlined),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Check-in · Realizada · Formulario',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildManagements() {
    final records = widget.store.gestionesForOpportunity(widget.opportunity.id);
    final isClosing = _isClosureStage(managementStageId);
    return Column(
      key: const ValueKey('opportunity-managements'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(
          eyebrow: 'Historial',
          title: 'Gestiones registradas',
        ),
        const SizedBox(height: 10),
        if (records.isEmpty)
          const EmptyBlock(text: 'Aun no hay gestiones para esta oportunidad.')
        else
          for (final record in records) GestionHistoryCard(record: record),
        const SizedBox(height: 18),
        const SectionTitle(eyebrow: 'Nuevo registro', title: 'Nueva gestion'),
        const SizedBox(height: 12),
        TextField(
          controller: dateController,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: 'Fecha',
            prefixIcon: Icon(Icons.event_outlined),
          ),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          initialValue: managementStageId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Etapa a la que pasa',
            prefixIcon: Icon(Icons.route_outlined),
          ),
          items: [
            for (final stage in widget.store.stages)
              DropdownMenuItem(
                value: stage.id,
                child: Text(
                  '${stage.id}. ${stage.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) =>
              setState(() => managementStageId = value ?? managementStageId),
        ),
        if (isClosing) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: closureResult,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Resultado de cierre',
              prefixIcon: Icon(Icons.flag_outlined),
            ),
            items: const [
              DropdownMenuItem(value: 'ganado', child: Text('Ganado')),
              DropdownMenuItem(value: 'perdida', child: Text('Perdida')),
            ],
            onChanged: (value) =>
                setState(() => closureResult = value ?? closureResult),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: commentController,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Comentario de la gestion',
            hintText: 'Detalle de la gestion realizada',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: saving ? null : _saveManagement,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_task_outlined),
            label: const Text('Agregar gestion'),
          ),
        ),
      ],
    );
  }

  Future<void> _saveManagement() async {
    if (commentController.text.trim().isEmpty) return;
    setState(() => saving = true);
    await widget.onSaveGestion(
      OpportunityGestionDraft(
        date: dateController.text.trim(),
        stageId: managementStageId,
        closureResult: _isClosureStage(managementStageId) ? closureResult : '',
        comment: commentController.text.trim(),
      ),
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  bool _isClosureStage(int stageId) {
    for (final stage in widget.store.stages) {
      if (stage.id != stageId) continue;
      return stage.id == 6 || stage.name.toLowerCase().contains('cierre');
    }
    return stageId == 6;
  }
}

class OpportunitySheetTabButton extends StatelessWidget {
  const OpportunitySheetTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected ? AppColors.page : AppColors.muted,
        backgroundColor: selected ? AppColors.green : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class GestionHistoryCard extends StatelessWidget {
  const GestionHistoryCard({required this.record, super.key});

  final GestionRecord record;

  @override
  Widget build(BuildContext context) {
    final hasClosureResult =
        record.result == 'ganado' || record.result == 'perdida';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${record.date} · ${record.time}',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (hasClosureResult)
                  CompactOpportunityMeta(
                    icon: record.result == 'ganado'
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    text: record.result == 'ganado' ? 'Ganado' : 'Perdida',
                    highlighted: record.result == 'ganado',
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              record.stageName,
              style: const TextStyle(
                color: AppColors.green,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(record.note),
          ],
        ),
      ),
    );
  }
}

class ScheduledGestionSheet extends StatefulWidget {
  const ScheduledGestionSheet({
    required this.store,
    required this.onSave,
    super.key,
  });

  final SalesStore store;
  final ValueChanged<ScheduledGestionDraft> onSave;

  @override
  State<ScheduledGestionSheet> createState() => _ScheduledGestionSheetState();
}

class _ScheduledGestionSheetState extends State<ScheduledGestionSheet> {
  String? opportunityId;
  String type = 'Visita';
  final date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  final time = TextEditingController(text: '09:00');
  final place = TextEditingController(text: 'Cliente');
  final note = TextEditingController();
  String message = '';

  @override
  void initState() {
    super.initState();
    final opportunities = widget.store.myActiveOpportunities;
    opportunityId = opportunities.isEmpty ? null : opportunities.first.id;
  }

  @override
  void dispose() {
    date.dispose();
    time.dispose();
    place.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opportunities = widget.store.myActiveOpportunities;
    return SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Nueva gestion',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          const Text(
            'Selecciona una oportunidad antes de agendar.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          if (opportunities.isEmpty)
            const EmptyBlock(
              text: 'No hay oportunidades vigentes para programar gestiones.',
            )
          else ...[
            DropdownButtonFormField<String>(
              initialValue: opportunityId,
              decoration: const InputDecoration(labelText: 'Oportunidad'),
              items: [
                for (final opportunity in opportunities)
                  DropdownMenuItem(
                    value: opportunity.id,
                    child: Text(
                      opportunity.company,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => opportunityId = value),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Tipo de gestion'),
              items: const [
                DropdownMenuItem(value: 'Visita', child: Text('Visita')),
                DropdownMenuItem(value: 'Llamada', child: Text('Llamada')),
                DropdownMenuItem(value: 'WhatsApp', child: Text('WhatsApp')),
                DropdownMenuItem(value: 'Correo', child: Text('Correo')),
              ],
              onChanged: (value) => setState(() => type = value ?? type),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: date,
                    decoration: const InputDecoration(labelText: 'Fecha'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: time,
                    decoration: const InputDecoration(labelText: 'Hora'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: place,
              decoration: const InputDecoration(labelText: 'Lugar'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: note,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Nota',
                hintText: 'Objetivo, contacto o detalle de la gestion',
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(message, style: const TextStyle(color: AppColors.yellow)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  final selected = opportunityId;
                  if (selected == null || selected.isEmpty) {
                    setState(
                      () => message =
                          'Selecciona una oportunidad para programar.',
                    );
                    return;
                  }
                  widget.onSave(
                    ScheduledGestionDraft(
                      opportunityId: selected,
                      type: type,
                      date: date.text.trim(),
                      time: time.text.trim(),
                      place: place.text.trim(),
                      note: note.text.trim(),
                    ),
                  );
                },
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Programar gestion'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class FormCaptureSheet extends StatefulWidget {
  const FormCaptureSheet({required this.form, required this.onSave, super.key});

  final StageForm form;
  final ValueChanged<Map<String, String>> onSave;

  @override
  State<FormCaptureSheet> createState() => _FormCaptureSheetState();
}

class _FormCaptureSheetState extends State<FormCaptureSheet> {
  final values = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    for (final field in widget.form.fields.take(6)) {
      values[field] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in values.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.form.name,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Etapa ${widget.form.stageId}',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          for (final entry in values.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: entry.value,
                decoration: InputDecoration(labelText: entry.key),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                widget.onSave(
                  values.map((key, value) => MapEntry(key, value.text)),
                );
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('Guardar captura'),
            ),
          ),
        ],
      ),
    );
  }
}

class OpportunityEditorSheet extends StatefulWidget {
  const OpportunityEditorSheet({
    required this.store,
    required this.onSave,
    this.opportunity,
    this.onDelete,
    super.key,
  });

  final SalesStore store;
  final Opportunity? opportunity;
  final ValueChanged<OpportunityDraft> onSave;
  final VoidCallback? onDelete;

  @override
  State<OpportunityEditorSheet> createState() => _OpportunityEditorSheetState();
}

class _OpportunityEditorSheetState extends State<OpportunityEditorSheet> {
  late final TextEditingController startDate;
  late final TextEditingController deadline;
  late final TextEditingController company;
  late final TextEditingController product;
  late final TextEditingController amount;
  late final TextEditingController closePercent;
  late final TextEditingController strategy;
  late final TextEditingController phone;
  late final TextEditingController responsible;
  late final TextEditingController comment;
  late int stageId;
  late String status;
  String closureResult = 'ganado';

  @override
  void initState() {
    super.initState();
    final opportunity = widget.opportunity;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    startDate = TextEditingController(text: opportunity?.startDate ?? today);
    deadline = TextEditingController(text: opportunity?.deadline ?? today);
    company = TextEditingController(text: opportunity?.company ?? '');
    product = TextEditingController(text: opportunity?.product ?? '');
    amount = TextEditingController(
      text: opportunity == null ? '' : opportunity.amount.toStringAsFixed(0),
    );
    closePercent = TextEditingController(
      text: opportunity == null ? '10' : '${opportunity.closePercent}',
    );
    strategy = TextEditingController(text: opportunity?.strategy ?? '');
    phone = TextEditingController(text: opportunity?.phone ?? '');
    responsible = TextEditingController(text: opportunity?.responsible ?? '');
    comment = TextEditingController(text: opportunity?.comment ?? '');
    stageId = opportunity?.stageId ?? 1;
    status = opportunity?.status ?? 'Vigente';
    closureResult = status.toLowerCase() == 'perdida' ? 'perdida' : 'ganado';
    if (!_isClosureStage(stageId) && _isClosedStatus(status)) {
      status = 'Vigente';
    }
  }

  @override
  void dispose() {
    startDate.dispose();
    deadline.dispose();
    company.dispose();
    product.dispose();
    amount.dispose();
    closePercent.dispose();
    strategy.dispose();
    phone.dispose();
    responsible.dispose();
    comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.business_center_outlined,
                color: AppColors.green,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.opportunity == null
                      ? 'Nueva oportunidad'
                      : 'Editar oportunidad',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Vendedor: ${widget.store.currentSeller.name}',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: startDate,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Fecha inicio'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: deadline,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Fecha limite'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: company,
            decoration: const InputDecoration(labelText: 'Empresa'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: product,
            decoration: const InputDecoration(labelText: 'Producto'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Venta probable',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: closePercent,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '% cierre'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            initialValue: stageId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Etapa'),
            items: [
              for (final stage in widget.store.stages)
                DropdownMenuItem(
                  value: stage.id,
                  child: Text(
                    '${stage.id}. ${stage.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              setState(() {
                stageId = value ?? stageId;
                if (_isClosureStage(stageId)) {
                  status = _statusFromClosureResult();
                } else if (_isClosedStatus(status)) {
                  status = 'Vigente';
                }
              });
            },
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _isClosureStage(stageId)
                ? DropdownButtonFormField<String>(
                    key: const ValueKey('closure-result'),
                    initialValue: closureResult,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Resultado de cierre',
                      prefixIcon: Icon(Icons.flag_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ganado', child: Text('Ganado')),
                      DropdownMenuItem(
                        value: 'perdida',
                        child: Text('Perdida'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        closureResult = value ?? closureResult;
                        status = _statusFromClosureResult();
                      });
                    },
                  )
                : DropdownButtonFormField<String>(
                    key: const ValueKey('opportunity-status'),
                    initialValue: status,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Estatus'),
                    items: const [
                      DropdownMenuItem(
                        value: 'Vigente',
                        child: Text('Vigente'),
                      ),
                      DropdownMenuItem(
                        value: 'En negociacion',
                        child: Text('En negociacion'),
                      ),
                      DropdownMenuItem(
                        value: 'Pausada',
                        child: Text('Pausada'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => status = value ?? status),
                  ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: strategy,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Estrategia'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Telefono'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: responsible,
                  decoration: const InputDecoration(labelText: 'Responsable'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: comment,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Comentario'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (widget.onDelete != null)
                IconButton.outlined(
                  tooltip: 'Eliminar oportunidad',
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline, color: AppColors.red),
                ),
              if (widget.onDelete != null) const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: submit,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Guardar oportunidad'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void submit() {
    final savedStatus =
        _isClosureStage(stageId) ? _statusFromClosureResult() : status;
    widget.onSave(
      OpportunityDraft(
        startDate: startDate.text,
        deadline: deadline.text,
        company: company.text,
        product: product.text,
        amount: double.tryParse(amount.text.replaceAll(',', '.')) ?? 0,
        stageId: stageId,
        closePercent: int.tryParse(closePercent.text) ?? 0,
        strategy: strategy.text,
        status: savedStatus,
        phone: phone.text,
        responsible: responsible.text,
        comment: comment.text,
      ),
    );
  }

  bool _isClosureStage(int candidateStageId) {
    for (final stage in widget.store.stages) {
      if (stage.id != candidateStageId) continue;
      final name = stage.name.toLowerCase();
      return name.contains('cierre') || stage.id == 6;
    }
    return candidateStageId == 6;
  }

  bool _isClosedStatus(String value) {
    final normalized = value.toLowerCase();
    return normalized == 'ganada' || normalized == 'perdida';
  }

  String _statusFromClosureResult() {
    return closureResult == 'ganado' ? 'Ganada' : 'Perdida';
  }
}

class ProfileSheet extends StatefulWidget {
  const ProfileSheet({
    required this.seller,
    required this.onSave,
    required this.onDelete,
    required this.onLogout,
    super.key,
  });

  final SalesUser seller;
  final ValueChanged<SellerDraft> onSave;
  final VoidCallback onDelete;
  final VoidCallback onLogout;

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  late final TextEditingController firstNameController;
  late final TextEditingController lastNameController;
  late final TextEditingController duiController;
  late final TextEditingController addressController;
  late final TextEditingController phoneController;
  late final TextEditingController emailController;

  @override
  void initState() {
    super.initState();
    firstNameController = TextEditingController(text: widget.seller.firstName);
    lastNameController = TextEditingController(text: widget.seller.lastName);
    duiController = TextEditingController(text: widget.seller.dui);
    addressController = TextEditingController(text: widget.seller.address);
    phoneController = TextEditingController(text: widget.seller.phone);
    emailController = TextEditingController(text: widget.seller.email);
  }

  @override
  void dispose() {
    firstNameController.dispose();
    lastNameController.dispose();
    duiController.dispose();
    addressController.dispose();
    phoneController.dispose();
    emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(initials: widget.seller.initials),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Mi perfil',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: firstNameController,
            decoration: const InputDecoration(labelText: 'Nombres'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: lastNameController,
            decoration: const InputDecoration(labelText: 'Apellidos'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: duiController,
            decoration: const InputDecoration(labelText: 'DUI'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: addressController,
            decoration: const InputDecoration(labelText: 'Direccion'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phoneController,
            decoration: const InputDecoration(labelText: 'Telefono'),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            decoration: const InputDecoration(labelText: 'Correo'),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => widget.onSave(
                SellerDraft(
                  firstName: firstNameController.text.trim(),
                  lastName: lastNameController.text.trim(),
                  dui: duiController.text.trim(),
                  address: addressController.text.trim(),
                  phone: phoneController.text.trim(),
                  email: emailController.text.trim(),
                ),
              ),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Guardar cambios'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout_outlined),
                  label: const Text('Cerrar sesion'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Eliminar perfil',
                onPressed: widget.onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SheetShell extends StatelessWidget {
  const SheetShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.line),
            ),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 34,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.eyebrow, required this.title, super.key});

  final String eyebrow;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: const TextStyle(
            color: AppColors.green,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({required this.status, super.key});

  final VisitStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      VisitStatus.scheduled => AppColors.cyan,
      VisitStatus.inVisit => AppColors.yellow,
      VisitStatus.done => AppColors.green,
      VisitStatus.pending => AppColors.muted,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class StageProgress extends StatelessWidget {
  const StageProgress({required this.stageId, this.max = 8, super.key});

  final int stageId;
  final int max;

  @override
  Widget build(BuildContext context) {
    final value = max == 0 ? 0.0 : (stageId / max).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: LinearProgressIndicator(
        minHeight: 8,
        value: value,
        color: AppColors.green,
        backgroundColor: Colors.white.withValues(alpha: 0.08),
      ),
    );
  }
}

class CountPill extends StatelessWidget {
  const CountPill({required this.value, super.key});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: AppColors.green,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.ink, fontSize: 12),
      ),
    );
  }
}

class DetailTile extends StatelessWidget {
  const DetailTile({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class EmptyBlock extends StatelessWidget {
  const EmptyBlock({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.muted),
      ),
    );
  }
}

class KonfiApiClient {
  const KonfiApiClient(this.baseUrl, {this.pathPrefix = apiPathPrefix});

  final String baseUrl;
  final String pathPrefix;

  Uri _uri(String path) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPrefix =
        pathPrefix.startsWith('/') ? pathPrefix : '/$pathPrefix';
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanBase$cleanPrefix$cleanPath');
  }

  Uri _systemUri(String path) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanBase$cleanPath');
  }

  Future<SalesStore> loadStore({SalesStore? previous}) async {
    final response = await http.get(_uri('/bootstrap'));
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> login(LoginDraft draft, {SalesStore? previous}) async {
    final response = await http.post(
      _uri('/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': draft.username,
        'password': draft.password,
      }),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> updateAgendaStatus(
    String agendaId,
    VisitStatus status, {
    SalesStore? previous,
  }) async {
    final response = await http.patch(
      _uri('/agenda/$agendaId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'status': status.label}),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> createGestion(
    String opportunityId,
    OpportunityGestionDraft draft, {
    AgendaItem? agenda,
    SalesStore? previous,
  }) async {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final response = await http.post(
      _uri('/gestiones'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'opportunityId': opportunityId,
        'type': 'Gestion app',
        'date': draft.date,
        'time': time,
        'status': 'Realizada',
        'stageId': draft.stageId,
        'result': draft.closureResult,
        'note': draft.comment,
        'agendaId': agenda?.id,
        'place': agenda?.place,
        'locationLabel': agenda == null
            ? 'Ubicacion no capturada'
            : '${agenda.place} - enviada desde app',
        'source': 'App vendedor',
      }),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> createScheduledGestion(
    ScheduledGestionDraft draft, {
    SalesStore? previous,
  }) async {
    final response = await http.post(
      _uri('/gestiones'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'opportunityId': draft.opportunityId,
        'type': draft.type,
        'date': draft.date,
        'time': draft.time,
        'status': 'Programada',
        'note': draft.note,
        'place': draft.place,
      }),
    );
    return _decodeStore(response, previous: previous);
  }

  Map<String, Object?> _opportunityPayload(
    OpportunityDraft draft,
    String ownerId,
    String source,
  ) {
    final nextDate = draft.deadline.isEmpty
        ? DateTime.now().toIso8601String().substring(0, 10)
        : draft.deadline;
    return {
      'startDate': draft.startDate,
      'deadline': draft.deadline,
      'company': draft.company.isEmpty ? 'Nueva oportunidad' : draft.company,
      'product': draft.product,
      'contact': draft.responsible,
      'phone': draft.phone,
      'segment': draft.product.isEmpty ? 'Producto pendiente' : draft.product,
      'location': 'Por definir',
      'stageId': draft.stageId,
      'priority': draft.closePercent >= 70 ? 'Alta' : 'Media',
      'temperature': draft.closePercent >= 70 ? 'Caliente' : 'Tibio',
      'estimatedAmount': draft.amount,
      'closePercent': draft.closePercent,
      'strategy': draft.strategy,
      'status': draft.status,
      'responsible': draft.responsible,
      'ownerId': ownerId,
      'source': source,
      'nextAction':
          draft.strategy.isEmpty ? 'Seguimiento comercial' : draft.strategy,
      'nextDate': nextDate,
      'lastNote': draft.comment,
      'comment': draft.comment,
      'agendaDate': nextDate,
      'agendaTime': '09:00',
      'agendaType': 'Seguimiento',
      'agendaPlace': 'Por definir',
      'agendaStatus': VisitStatus.scheduled.label,
    };
  }

  Future<SalesStore> createOpportunity(
    OpportunityDraft draft,
    String ownerId, {
    SalesStore? previous,
    String source = 'App vendedor',
  }) async {
    final response = await http.post(
      _uri('/opportunities'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(_opportunityPayload(draft, ownerId, source)),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> updateOpportunity(
    String opportunityId,
    OpportunityDraft draft,
    String ownerId, {
    SalesStore? previous,
  }) async {
    final response = await http.patch(
      _uri('/opportunities/$opportunityId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(_opportunityPayload(draft, ownerId, 'App vendedor')),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> deleteOpportunity(
    String opportunityId, {
    SalesStore? previous,
  }) async {
    final response = await http.delete(_uri('/opportunities/$opportunityId'));
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> createSeller(
    SellerDraft draft, {
    SalesStore? previous,
  }) async {
    final response = await http.post(
      _uri('/users'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'firstName': draft.firstName,
        'lastName': draft.lastName,
        'name': draft.fullName,
        'dui': draft.dui,
        'address': draft.address,
        'phone': draft.phone,
        'email': draft.email,
        'username': draft.email,
        'password': draft.password,
        'territory': draft.address,
        'roleId': 'sales_exec',
      }),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> updateSeller(
    String sellerId,
    SellerDraft draft, {
    SalesStore? previous,
  }) async {
    final response = await http.patch(
      _uri('/users/$sellerId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'firstName': draft.firstName,
        'lastName': draft.lastName,
        'name': draft.fullName,
        'dui': draft.dui,
        'address': draft.address,
        'phone': draft.phone,
        'email': draft.email,
        'username': draft.email,
        'password': draft.password,
        'territory': draft.address,
        'roleId': 'sales_exec',
      }),
    );
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> deleteSeller(
    String sellerId, {
    SalesStore? previous,
  }) async {
    final response = await http.delete(_uri('/users/$sellerId'));
    return _decodeStore(response, previous: previous);
  }

  Future<SalesStore> _decodeStore(
    http.Response response, {
    SalesStore? previous,
  }) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('API ${response.statusCode}: ${response.body}');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final sessionRole = _text(_map(payload['sessionUser'])['role']);
    final isManagerSession = {'gerencias', 'jefaturas'}.contains(sessionRole) ||
        (previous?.currentSeller.isManager ?? false);
    if (isManagerSession) {
      try {
        final managementResponse = await http.get(
          _systemUri('/api/opportunities'),
        );
        if (managementResponse.statusCode >= 200 &&
            managementResponse.statusCode < 300) {
          final managementPayload = jsonDecode(managementResponse.body);
          final managementSummary =
              _visibleManagerialOpportunitySummary(managementPayload);
          payload['managerialOpportunityCount'] = managementSummary.count;
          payload['managerialOpportunityTotal'] = managementSummary.total;
        }
      } catch (_) {
        // La vista conserva el ultimo conteo si el resumen gerencial no responde.
      }
    }
    payload['managerialOpportunityCount'] ??=
        previous?.managerialOpportunityCount;
    payload['managerialOpportunityTotal'] ??=
        previous?.managerialOpportunityTotal;
    return SalesStore.fromApi(payload, previous: previous);
  }

  ({int count, double total}) _visibleManagerialOpportunitySummary(
    Object? value,
  ) {
    if (value is! List) return (count: 0, total: 0);
    final now = DateTime.now();
    final periodStart = _isoMonthStart(now.year, now.month);
    final nextMonth = now.month == 12 ? 1 : now.month + 1;
    final nextYear = now.month == 12 ? now.year + 1 : now.year;
    final nextPeriodStart = _isoMonthStart(nextYear, nextMonth);
    var count = 0;
    var total = 0.0;
    for (final rawItem in value) {
      final item = _map(rawItem);
      final managements = _list(item['managements']);
      Map<String, dynamic>? latestClosure;
      for (final rawManagement in managements.reversed) {
        final management = _map(rawManagement);
        final stage = _text(management['stage']).toLowerCase();
        final result = _text(management['result']).toLowerCase();
        if (management['canceled'] != true &&
            {'cierre', 'cierre de ventas'}.contains(stage) &&
            result.isNotEmpty) {
          latestClosure = management;
          break;
        }
      }
      if (_text(latestClosure?['result']).toLowerCase() == 'perdida') {
        continue;
      }
      final closureDate = _text(latestClosure?['date']);
      final opportunityDate = _text(item['date']);
      final closedBeforePeriod =
          closureDate.isNotEmpty && closureDate.compareTo(periodStart) < 0;
      final scheduledForFuture = opportunityDate.isNotEmpty &&
          opportunityDate.compareTo(nextPeriodStart) >= 0;
      if (closedBeforePeriod || scheduledForFuture) continue;
      count += 1;
      total += _money(item['amount']);
    }
    return (count: count, total: total);
  }

  String _isoMonthStart(int year, int month) =>
      '$year-${month.toString().padLeft(2, '0')}-01';
}

List<dynamic> _list(Object? value) => value is List ? value : const [];

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

double _money(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _currency(double value) {
  final parts = value.toStringAsFixed(2).split('.');
  final digits = parts.first;
  final groups = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    final start = math.max(0, end - 3);
    groups.insert(0, digits.substring(start, end));
  }
  return '\$${groups.join(',')}.${parts.last}';
}

int _int(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

class SalesStore {
  SalesStore({
    required this.currentSeller,
    required this.sellers,
    required this.stages,
    required this.opportunities,
    required this.agenda,
    required this.forms,
    this.managerialOpportunityCount,
    this.managerialOpportunityTotal,
    List<GestionRecord>? gestiones,
    Map<String, List<Map<String, String>>>? formResponses,
    List<VisitResult>? visitResults,
  })  : gestiones = gestiones ?? [],
        formResponses = formResponses ?? {},
        visitResults = visitResults ?? [];

  final SalesUser currentSeller;
  final List<SalesUser> sellers;
  final List<SalesStage> stages;
  final List<Opportunity> opportunities;
  final List<AgendaItem> agenda;
  final List<StageForm> forms;
  final int? managerialOpportunityCount;
  final double? managerialOpportunityTotal;
  final List<GestionRecord> gestiones;
  final Map<String, List<Map<String, String>>> formResponses;
  final List<VisitResult> visitResults;

  static SalesStore seed() {
    return SalesStore(
      currentSeller: const SalesUser(
        id: 'u2',
        name: 'Carlos Rivera',
        initials: 'CR',
      ),
      sellers: const [
        SalesUser(
          id: 'u2',
          name: 'Carlos Rivera',
          initials: 'CR',
          roleId: 'sales_exec',
          phone: '+503 7000-2202',
          email: 'carlos@konfi.local',
          territory: 'San Salvador',
        ),
        SalesUser(
          id: 'u3',
          name: 'Sofia Menjivar',
          initials: 'SM',
          roleId: 'sales_exec',
          phone: '+503 7000-3303',
          email: 'sofia@konfi.local',
          territory: 'Santa Tecla',
        ),
      ],
      stages: const [
        SalesStage(1, 'Prospeccion', 'Calificar potencial real y segmento.'),
        SalesStage(
          2,
          'Contacto inicial',
          'Abrir relacion y coordinar reunion.',
        ),
        SalesStage(
          3,
          'Deteccion de necesidades',
          'Levantar informacion con SPIN/BANT.',
        ),
        SalesStage(
          4,
          'Presentacion de solucion',
          'Presentar propuesta y muestras.',
        ),
        SalesStage(
          5,
          'Objeciones',
          'Resolver dudas de precio, tiempo y calidad.',
        ),
        SalesStage(6, 'Cierre', 'Formalizar condiciones y anticipo.'),
        SalesStage(7, 'Compilado', 'Entregar informacion a produccion.'),
        SalesStage(8, 'Postventa', 'Medir satisfaccion, NPS y recompra.'),
      ],
      opportunities: [
        const Opportunity(
          id: 'opp-1003',
          startDate: '2026-06-10',
          deadline: '2026-06-30',
          company: 'Industrias La Union',
          product: 'Uniformes industriales',
          contact: 'Roberto Salinas',
          phone: '+503 7000-3303',
          segment: 'Industria',
          location: 'Soyapango',
          stageId: 6,
          stageName: 'Cierre de ventas',
          priority: 'Alta',
          temperature: 'Caliente',
          amount: 31200,
          closePercent: 80,
          strategy: 'Confirmar anticipo y orden de compra',
          status: 'Vigente',
          responsible: 'Roberto Salinas',
          ownerId: 'u2',
          nextAction: 'Confirmar anticipo y orden de compra',
          note: 'Aprobada propuesta tecnica; falta formalizacion.',
          comment: 'Aprobada propuesta tecnica; falta formalizacion.',
        ),
        const Opportunity(
          id: 'opp-1001',
          startDate: '2026-06-08',
          deadline: '2026-06-25',
          company: 'Hospital San Gabriel',
          product: 'Uniformes clinicos',
          contact: 'Lic. Patricia Gomez',
          phone: '+503 7000-1101',
          segment: 'Salud',
          location: 'San Salvador',
          stageId: 3,
          stageName: 'Deteccion de necesidades',
          priority: 'Alta',
          temperature: 'Caliente',
          amount: 18500,
          closePercent: 45,
          strategy: 'Validar tallaje y presupuesto por area',
          status: 'Vigente',
          responsible: 'Lic. Patricia Gomez',
          ownerId: 'u2',
          nextAction: 'Validar tallaje y presupuesto por area',
          note: 'Uniformes clinicos resistentes y entrega parcial en julio.',
          comment: 'Uniformes clinicos resistentes y entrega parcial en julio.',
        ),
        const Opportunity(
          id: 'opp-1005',
          startDate: '2026-06-05',
          deadline: '2026-07-05',
          company: 'Supermercados El Ahorro',
          product: 'Recompra de uniformes',
          contact: 'Diana Vasquez',
          phone: '+503 7000-5505',
          segment: 'Comercio',
          location: 'San Miguel',
          stageId: 8,
          stageName: 'Postventa',
          priority: 'Alta',
          temperature: 'Cliente',
          amount: 24600,
          closePercent: 90,
          strategy: 'Encuesta NPS y oportunidad de recompra',
          status: 'Vigente',
          responsible: 'Diana Vasquez',
          ownerId: 'u2',
          nextAction: 'Encuesta NPS y oportunidad de recompra',
          note: 'Entrega completada; pedir referido.',
          comment: 'Entrega completada; pedir referido.',
        ),
      ],
      agenda: [
        const AgendaItem(
          id: 'ag-1',
          opportunityId: 'opp-1003',
          date: '2026-06-11',
          time: '09:00',
          type: 'Cierre',
          place: 'Planta cliente',
          ownerId: 'u2',
          status: VisitStatus.scheduled,
        ),
        const AgendaItem(
          id: 'ag-2',
          opportunityId: 'opp-1001',
          date: '2026-06-11',
          time: '10:30',
          type: 'Diagnostico',
          place: 'Hospital San Gabriel',
          ownerId: 'u2',
          status: VisitStatus.scheduled,
        ),
        const AgendaItem(
          id: 'ag-4',
          opportunityId: 'opp-1005',
          date: '2026-06-14',
          time: '11:00',
          type: 'Postventa',
          place: 'Llamada WhatsApp',
          ownerId: 'u2',
          status: VisitStatus.pending,
        ),
      ],
      forms: const [
        StageForm(1, 'Base de prospectos', [
          'Empresa',
          'Segmento',
          'Contacto',
          'Telefono',
          'Necesidad',
          'Monto estimado',
        ]),
        StageForm(2, 'Solicitud de muestras', [
          'Cantidad',
          'Tipo de prenda',
          'Tela',
          'Referencia',
          'Fecha requerida',
        ]),
        StageForm(3, 'SPIN/BANT', [
          'Situacion',
          'Problema',
          'Impacto',
          'Necesidad',
          'Presupuesto',
          'Autoridad',
        ]),
        StageForm(4, 'Presentacion de solucion', [
          'Propuesta',
          'Muestras',
          'Beneficios',
          'Condiciones',
          'Siguiente paso',
        ]),
        StageForm(5, 'Registro de objeciones', [
          'Objecion',
          'Causa',
          'Respuesta',
          'Evidencia',
          'Estado',
        ]),
        StageForm(6, 'Cierre de ventas', [
          'Condiciones',
          'Anticipo',
          'Orden compra',
          'Tallas',
          'Fecha entrega',
        ]),
        StageForm(8, 'Encuesta postventa', [
          'Satisfaccion',
          'NPS',
          'Incidencias',
          'Referidos',
          'Recompra',
        ]),
      ],
    );
  }

  factory SalesStore.fromApi(
    Map<String, dynamic> json, {
    SalesStore? previous,
  }) {
    final users = _list(
      json['users'],
    ).map((item) => SalesUser.fromJson(_map(item))).toList();
    final stages = _list(
      json['stages'],
    ).map((item) => SalesStage.fromJson(_map(item))).toList();
    final opportunities = _list(
      json['opportunities'],
    ).map((item) => Opportunity.fromJson(_map(item), stages)).toList();
    final agenda = _list(
      json['agenda'],
    ).map((item) => AgendaItem.fromJson(_map(item))).toList();
    final forms = _list(
      json['forms'],
    ).map((item) => StageForm.fromJson(_map(item))).toList();
    final gestiones = _list(
      json['gestiones'],
    ).map((item) => GestionRecord.fromJson(_map(item), stages)).toList();
    final sessionUser = _map(json['sessionUser']);
    final sessionRole = _text(sessionUser['role']);
    final managerSession = {'gerencias', 'jefaturas'}.contains(sessionRole);

    SalesUser pickSeller() {
      final activeUserId = _text(json['activeUserId']);
      for (final user in users) {
        if (activeUserId.isNotEmpty && user.id == activeUserId) return user;
      }
      for (final user in users) {
        if (user.id == (previous?.currentSeller.id ?? 'u2')) return user;
      }
      return users.isNotEmpty ? users.first : SalesStore.seed().currentSeller;
    }

    final crmSeller = pickSeller();
    final sessionName = _text(sessionUser['name']);
    final currentSeller = managerSession
        ? SalesUser.fromJson({
            'id': _text(sessionUser['id'], 'manager'),
            'name': _text(sessionUser['name'], 'Gerencia comercial'),
            'email': _text(sessionUser['email']),
            'username': _text(sessionUser['username']),
            'roleId': 'sales_manager',
            'territory': 'Vista general',
          })
        : sessionName.isEmpty
            ? crmSeller
            : SalesUser(
                id: crmSeller.id,
                name: sessionName,
                initials: SalesUser.initialsFromName(sessionName),
                firstName: _text(
                  sessionUser['firstName'],
                  sessionName.split(' ').first,
                ),
                lastName: _text(sessionUser['lastName']),
                dui: crmSeller.dui,
                address: crmSeller.address,
                roleId: crmSeller.roleId,
                phone: crmSeller.phone,
                email: _text(sessionUser['email'], crmSeller.email),
                territory: crmSeller.territory,
              );

    return SalesStore(
      currentSeller: currentSeller,
      sellers: users.isNotEmpty ? users : SalesStore.seed().sellers,
      stages: stages.isNotEmpty ? stages : SalesStore.seed().stages,
      opportunities: opportunities,
      agenda: agenda,
      forms: forms.isNotEmpty ? forms : SalesStore.seed().forms,
      managerialOpportunityCount: json['managerialOpportunityCount'] == null
          ? previous?.managerialOpportunityCount
          : _int(json['managerialOpportunityCount']),
      managerialOpportunityTotal: json['managerialOpportunityTotal'] == null
          ? previous?.managerialOpportunityTotal
          : _money(json['managerialOpportunityTotal']),
      gestiones: gestiones,
      formResponses: previous == null
          ? {}
          : previous.formResponses.map(
              (key, value) => MapEntry(
                key,
                value.map((row) => Map<String, String>.from(row)).toList(),
              ),
            ),
      visitResults: previous == null ? [] : List.of(previous.visitResults),
    );
  }

  SalesStore withSeller(SalesUser seller) {
    return SalesStore(
      currentSeller: seller,
      sellers: sellers,
      stages: stages,
      opportunities: opportunities,
      agenda: agenda,
      forms: forms,
      managerialOpportunityCount: managerialOpportunityCount,
      managerialOpportunityTotal: managerialOpportunityTotal,
      gestiones: gestiones,
      formResponses: formResponses,
      visitResults: visitResults,
    );
  }

  SalesStore withAddedSeller(SalesUser seller) {
    final nextSellers = [
      ...sellers.where((item) => item.id != seller.id),
      seller,
    ];
    return SalesStore(
      currentSeller: seller,
      sellers: nextSellers,
      stages: stages,
      opportunities: opportunities,
      agenda: agenda,
      forms: forms,
      managerialOpportunityCount: managerialOpportunityCount,
      managerialOpportunityTotal: managerialOpportunityTotal,
      gestiones: gestiones,
      formResponses: formResponses,
      visitResults: visitResults,
    );
  }

  SalesStore withUpdatedSeller(SalesUser seller) {
    return SalesStore(
      currentSeller: seller,
      sellers:
          sellers.map((item) => item.id == seller.id ? seller : item).toList(),
      stages: stages,
      opportunities: opportunities,
      agenda: agenda,
      forms: forms,
      managerialOpportunityCount: managerialOpportunityCount,
      managerialOpportunityTotal: managerialOpportunityTotal,
      gestiones: gestiones,
      formResponses: formResponses,
      visitResults: visitResults,
    );
  }

  SalesStore withoutSeller(String sellerId) {
    final nextSellers = sellers.where((item) => item.id != sellerId).toList();
    final nextSeller = nextSellers.isNotEmpty
        ? nextSellers.first
        : SalesStore.seed().currentSeller;
    return SalesStore(
      currentSeller: nextSeller,
      sellers: nextSellers,
      stages: stages,
      opportunities: opportunities,
      agenda: agenda,
      forms: forms,
      managerialOpportunityCount: managerialOpportunityCount,
      managerialOpportunityTotal: managerialOpportunityTotal,
      gestiones: gestiones,
      formResponses: formResponses,
      visitResults: visitResults,
    );
  }

  List<Opportunity> get myOpportunities =>
      opportunities.where((item) => item.ownerId == currentSeller.id).toList();

  List<Opportunity> get myActiveOpportunities => myOpportunities
      .where(
        (item) => !{
          'ganada',
          'perdida',
          'cancelada',
        }.contains(item.status.toLowerCase()),
      )
      .toList()
    ..sort((a, b) => a.deadline.compareTo(b.deadline));

  List<AgendaItem> get myAgenda =>
      agenda.where((item) => item.ownerId == currentSeller.id).toList();

  int get inVisitCount =>
      myAgenda.where((item) => item.status == VisitStatus.inVisit).length;

  int get doneCount =>
      myAgenda.where((item) => item.status == VisitStatus.done).length;

  int get hotCount =>
      myOpportunities.where((item) => item.temperature == 'Caliente').length;

  int get totalResponses =>
      formResponses.values.fold<int>(0, (sum, item) => sum + item.length);

  String get pipelineLabel {
    final total = myOpportunities.fold<double>(
      0,
      (sum, item) => sum + item.amount,
    );
    if (total >= 1000) return '\$${(total / 1000).toStringAsFixed(1)}k';
    return '\$${total.toStringAsFixed(0)}';
  }

  List<AgendaItem> filteredAgenda(String filter) {
    final items = [...myAgenda]
      ..sort((a, b) => '${a.date} ${a.time}'.compareTo('${b.date} ${b.time}'));
    if (filter == 'Hoy') {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final visibleDate = items.any((item) => item.date == today)
          ? today
          : _firstAgendaDate(items);
      return visibleDate == null
          ? []
          : items.where((item) => item.date == visibleDate).toList();
    }
    return items;
  }

  List<AgendaItem> agendaForDate(String date) {
    final items = [...myAgenda.where((item) => item.date == date)]
      ..sort((a, b) => '${a.date} ${a.time}'.compareTo('${b.date} ${b.time}'));
    return items;
  }

  Opportunity opportunityById(String id) {
    return opportunities.firstWhere((item) => item.id == id);
  }

  AgendaItem? agendaForOpportunity(String opportunityId) {
    for (final item in agenda) {
      if (item.opportunityId == opportunityId) return item;
    }
    return null;
  }

  List<GestionRecord> gestionesForOpportunity(String opportunityId) {
    final items =
        gestiones.where((item) => item.opportunityId == opportunityId).toList();
    items.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return items;
  }

  StageForm formForStage(int stageId) {
    return forms.firstWhere(
      (item) => item.stageId == stageId,
      orElse: () => forms.first,
    );
  }

  void updateAgendaStatus(String agendaId, VisitStatus status) {
    final index = agenda.indexWhere((item) => item.id == agendaId);
    if (index == -1) return;
    agenda[index] = agenda[index].copyWith(status: status);
  }

  void addVisitResult(String opportunityId, String result, String note) {
    visitResults.add(
      VisitResult(
        opportunityId: opportunityId,
        result: result,
        note: note,
        createdAt: DateTime.now(),
      ),
    );
  }

  void saveFormResponse(String formId, Map<String, String> values) {
    formResponses.putIfAbsent(formId, () => []).add(values);
  }

  void saveOpportunityDraft(OpportunityDraft draft, {String? opportunityId}) {
    final id = opportunityId ?? 'opp-${DateTime.now().millisecondsSinceEpoch}';
    final stage = stages.firstWhere(
      (item) => item.id == draft.stageId,
      orElse: () => stages.first,
    );
    final opportunity = Opportunity(
      id: id,
      startDate: draft.startDate,
      deadline: draft.deadline,
      company: draft.company.isEmpty ? 'Nueva oportunidad' : draft.company,
      product: draft.product,
      contact: draft.responsible,
      phone: draft.phone,
      segment: draft.product.isEmpty ? 'Producto pendiente' : draft.product,
      location: 'Por definir',
      stageId: draft.stageId,
      stageName: stage.name,
      priority: draft.closePercent >= 70 ? 'Alta' : 'Media',
      temperature: draft.closePercent >= 70 ? 'Caliente' : 'Tibio',
      amount: draft.amount,
      closePercent: draft.closePercent,
      strategy: draft.strategy,
      status: draft.status,
      responsible: draft.responsible,
      ownerId: currentSeller.id,
      nextAction:
          draft.strategy.isEmpty ? 'Seguimiento comercial' : draft.strategy,
      note: draft.comment,
      comment: draft.comment,
    );
    final index = opportunities.indexWhere((item) => item.id == id);
    if (index == -1) {
      opportunities.add(opportunity);
    } else {
      opportunities[index] = opportunity;
    }

    agenda.removeWhere((item) => item.opportunityId == id);
    agenda.add(
      AgendaItem(
        id: 'ag-${DateTime.now().millisecondsSinceEpoch}',
        opportunityId: id,
        date: draft.deadline.isEmpty
            ? DateTime.now().toIso8601String().substring(0, 10)
            : draft.deadline,
        time: '09:00',
        type: 'Seguimiento',
        place: 'Por definir',
        ownerId: currentSeller.id,
        status: VisitStatus.scheduled,
      ),
    );
  }

  void deleteOpportunity(String opportunityId) {
    opportunities.removeWhere((item) => item.id == opportunityId);
    agenda.removeWhere((item) => item.opportunityId == opportunityId);
  }

  String? _firstAgendaDate(List<AgendaItem> items) {
    return items.isEmpty ? null : items.first.date;
  }
}

class SalesUser {
  const SalesUser({
    required this.id,
    required this.name,
    required this.initials,
    this.firstName = '',
    this.lastName = '',
    this.dui = '',
    this.address = '',
    this.roleId = 'sales_exec',
    this.phone = '',
    this.email = '',
    this.territory = 'Por definir',
  });

  final String id;
  final String name;
  final String initials;
  final String firstName;
  final String lastName;
  final String dui;
  final String address;
  final String roleId;
  final String phone;
  final String email;
  final String territory;

  bool get isManager =>
      {'sales_manager', 'gerencias', 'jefaturas'}.contains(roleId);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'initials': initials,
        'firstName': firstName,
        'lastName': lastName,
        'dui': dui,
        'address': address,
        'roleId': roleId,
        'phone': phone,
        'email': email,
        'territory': territory,
      };

  factory SalesUser.fromJson(Map<String, dynamic> json) {
    final name = _text(json['name'], 'Vendedor');
    final parsedFirstName = _text(json['firstName']);
    final parsedLastName = _text(json['lastName']);
    return SalesUser(
      id: _text(json['id'], 'u2'),
      name: name,
      initials: _text(json['initials'], initialsFromName(name)),
      firstName: parsedFirstName.isEmpty
          ? _firstNameFromFullName(name)
          : parsedFirstName,
      lastName:
          parsedLastName.isEmpty ? _lastNameFromFullName(name) : parsedLastName,
      dui: _text(json['dui']),
      address: _text(json['address']),
      roleId: _text(json['roleId'], 'sales_exec'),
      phone: _text(json['phone']),
      email: _text(json['email']),
      territory: _text(json['territory'], 'Por definir'),
    );
  }

  factory SalesUser.localFromDraft(SellerDraft draft) {
    return SalesUser(
      id: 'local-${DateTime.now().millisecondsSinceEpoch}',
      name: draft.fullName,
      initials: initialsFromName(draft.fullName),
      firstName: draft.firstName,
      lastName: draft.lastName,
      dui: draft.dui,
      address: draft.address,
      roleId: 'sales_exec',
      phone: draft.phone,
      email: draft.email,
      territory: draft.address.isEmpty ? 'Por definir' : draft.address,
    );
  }

  SalesUser updatedFromDraft(SellerDraft draft) {
    return SalesUser(
      id: id,
      name: draft.fullName.isEmpty ? name : draft.fullName,
      initials: initialsFromName(
        draft.fullName.isEmpty ? name : draft.fullName,
      ),
      firstName: draft.firstName,
      lastName: draft.lastName,
      dui: draft.dui,
      address: draft.address,
      roleId: roleId,
      phone: draft.phone,
      email: draft.email,
      territory: draft.address.isEmpty ? 'Por definir' : draft.address,
    );
  }

  static String _firstNameFromFullName(String name) {
    return name.split(' ').where((item) => item.isNotEmpty).take(1).join();
  }

  static String _lastNameFromFullName(String name) {
    final parts = name.split(' ').where((item) => item.isNotEmpty).toList();
    return parts.length <= 1 ? '' : parts.skip(1).join(' ');
  }

  static String initialsFromName(String name) {
    final parts = name.split(' ').where((item) => item.isNotEmpty).toList();
    if (parts.isEmpty) return 'KV';
    return parts.take(2).map((item) => item[0].toUpperCase()).join();
  }
}

class SalesStage {
  const SalesStage(this.id, this.name, this.goal);

  final int id;
  final String name;
  final String goal;

  factory SalesStage.fromJson(Map<String, dynamic> json) {
    return SalesStage(
      _int(json['id'], 1),
      _text(json['name'], 'Etapa'),
      _text(json['description'], 'Seguimiento comercial'),
    );
  }
}

class Opportunity {
  const Opportunity({
    required this.id,
    required this.startDate,
    required this.deadline,
    required this.company,
    required this.product,
    required this.contact,
    required this.phone,
    required this.segment,
    required this.location,
    required this.stageId,
    required this.stageName,
    required this.priority,
    required this.temperature,
    required this.amount,
    required this.closePercent,
    required this.strategy,
    required this.status,
    required this.responsible,
    required this.ownerId,
    required this.nextAction,
    required this.note,
    required this.comment,
    this.source = 'CRM',
  });

  final String id;
  final String startDate;
  final String deadline;
  final String company;
  final String product;
  final String contact;
  final String phone;
  final String segment;
  final String location;
  final int stageId;
  final String stageName;
  final String priority;
  final String temperature;
  final double amount;
  final int closePercent;
  final String strategy;
  final String status;
  final String responsible;
  final String ownerId;
  final String nextAction;
  final String note;
  final String comment;
  final String source;

  String get amountLabel {
    if (amount >= 1000) return '\$${amount.toStringAsFixed(0)}';
    return '\$${amount.toStringAsFixed(0)}';
  }

  String get deadlineLabel => deadline.isEmpty ? 'sin fecha' : deadline;

  factory Opportunity.fromJson(
    Map<String, dynamic> json,
    List<SalesStage> stages,
  ) {
    final stageId = _int(json['stageId'], 1);
    final stageFromPayload = _map(json['stage']);
    SalesStage? stage;
    for (final item in stages) {
      if (item.id == stageId) {
        stage = item;
        break;
      }
    }
    return Opportunity(
      id: _text(json['id']),
      startDate: _text(json['startDate']),
      deadline: _text(json['deadline'], _text(json['nextDate'])),
      company: _text(json['company'], 'Sin empresa'),
      product: _text(json['product'], _text(json['segment'])),
      contact: _text(json['contact'], 'Sin contacto'),
      phone: _text(json['phone'], 'Sin telefono'),
      segment: _text(json['segment'], 'Sin segmento'),
      location: _text(json['location'], 'Sin ubicacion'),
      stageId: stageId,
      stageName: _text(stageFromPayload['name'], stage?.name ?? 'Etapa'),
      priority: _text(json['priority'], 'Media'),
      temperature: _text(json['temperature'], 'Tibio'),
      amount: _money(json['estimatedAmount']),
      closePercent: _int(json['closePercent'], 0),
      strategy: _text(json['strategy'], _text(json['nextAction'])),
      status: _text(json['status'], 'Vigente'),
      responsible: _text(json['responsible'], _text(json['contact'])),
      ownerId: _text(json['ownerId'], 'u2'),
      nextAction: _text(json['nextAction'], 'Seguimiento pendiente'),
      note: _text(json['lastNote']),
      comment: _text(json['comment'], _text(json['lastNote'])),
      source: _text(json['source'], 'CRM'),
    );
  }
}

class AgendaItem {
  const AgendaItem({
    required this.id,
    required this.opportunityId,
    required this.date,
    required this.time,
    required this.type,
    required this.place,
    required this.ownerId,
    required this.status,
  });

  final String id;
  final String opportunityId;
  final String date;
  final String time;
  final String type;
  final String place;
  final String ownerId;
  final VisitStatus status;

  AgendaItem copyWith({VisitStatus? status}) {
    return AgendaItem(
      id: id,
      opportunityId: opportunityId,
      date: date,
      time: time,
      type: type,
      place: place,
      ownerId: ownerId,
      status: status ?? this.status,
    );
  }

  factory AgendaItem.fromJson(Map<String, dynamic> json) {
    return AgendaItem(
      id: _text(json['id']),
      opportunityId: _text(json['opportunityId']),
      date: _text(json['date']),
      time: _text(json['time'], '09:00'),
      type: _text(json['type'], 'Seguimiento'),
      place: _text(json['place'], 'Por definir'),
      ownerId: _text(json['ownerId'], 'u2'),
      status: VisitStatus.fromLabel(_text(json['status'])),
    );
  }
}

enum VisitStatus {
  scheduled('Programada'),
  inVisit('En visita'),
  done('Realizada'),
  pending('Pendiente');

  const VisitStatus(this.label);

  final String label;

  static VisitStatus fromLabel(String label) {
    return VisitStatus.values.firstWhere(
      (item) => item.label.toLowerCase() == label.toLowerCase(),
      orElse: () => VisitStatus.scheduled,
    );
  }
}

class StageForm {
  const StageForm(this.stageId, this.name, this.fields);

  String get id => 'form-$stageId';

  final int stageId;
  final String name;
  final List<String> fields;

  factory StageForm.fromJson(Map<String, dynamic> json) {
    final stageId = _int(json['stageId'], 1);
    final rawFields = _list(json['fields']);
    return StageForm(
      stageId,
      _text(json['name'], 'Formulario de etapa $stageId'),
      rawFields.map((field) {
        if (field is Map<String, dynamic>) {
          return _text(field['label'], _text(field['name'], 'Campo'));
        }
        return _text(field, 'Campo');
      }).toList(),
    );
  }
}

class VisitResult {
  const VisitResult({
    required this.opportunityId,
    required this.result,
    required this.note,
    required this.createdAt,
  });

  final String opportunityId;
  final String result;
  final String note;
  final DateTime createdAt;
}

class GestionRecord {
  const GestionRecord({
    required this.id,
    required this.opportunityId,
    required this.stageId,
    required this.stageName,
    required this.date,
    required this.time,
    required this.result,
    required this.note,
    required this.source,
  });

  final String id;
  final String opportunityId;
  final int stageId;
  final String stageName;
  final String date;
  final String time;
  final String result;
  final String note;
  final String source;

  String get sortKey => '$date $time';

  factory GestionRecord.fromJson(
    Map<String, dynamic> json,
    List<SalesStage> stages,
  ) {
    final stageId = _int(json['stageId']);
    var stageName = _text(json['stageName']);
    if (stageName.isEmpty) {
      for (final stage in stages) {
        if (stage.id == stageId) stageName = stage.name;
      }
    }
    return GestionRecord(
      id: _text(json['id']),
      opportunityId: _text(json['opportunityId']),
      stageId: stageId,
      stageName: stageName.isEmpty ? 'Seguimiento' : stageName,
      date: _text(json['date']),
      time: _text(json['time']),
      result: _text(json['result']),
      note: _text(json['note'], 'Gestion registrada'),
      source: _text(json['source'], 'CRM'),
    );
  }
}

class OpportunityGestionDraft {
  const OpportunityGestionDraft({
    required this.date,
    required this.stageId,
    required this.closureResult,
    required this.comment,
  });

  final String date;
  final int stageId;
  final String closureResult;
  final String comment;
}

class OpportunityDraft {
  const OpportunityDraft({
    required this.startDate,
    required this.deadline,
    required this.company,
    required this.product,
    required this.amount,
    required this.stageId,
    required this.closePercent,
    required this.strategy,
    required this.status,
    required this.phone,
    required this.responsible,
    required this.comment,
  });

  final String startDate;
  final String deadline;
  final String company;
  final String product;
  final double amount;
  final int stageId;
  final int closePercent;
  final String strategy;
  final String status;
  final String phone;
  final String responsible;
  final String comment;
}

class ScheduledGestionDraft {
  const ScheduledGestionDraft({
    required this.opportunityId,
    required this.type,
    required this.date,
    required this.time,
    required this.place,
    required this.note,
  });

  final String opportunityId;
  final String type;
  final String date;
  final String time;
  final String place;
  final String note;
}

class SellerDraft {
  const SellerDraft({
    required this.firstName,
    required this.lastName,
    required this.dui,
    required this.address,
    required this.phone,
    required this.email,
    this.password = '',
  });

  final String firstName;
  final String lastName;
  final String dui;
  final String address;
  final String phone;
  final String email;
  final String password;

  String get fullName => '$firstName $lastName'.trim();
}

class LoginDraft {
  const LoginDraft({required this.username, required this.password});

  final String username;
  final String password;
}

class KpiMetric {
  const KpiMetric(this.label, this.value, this.hint);

  final String label;
  final String value;
  final String hint;
}
