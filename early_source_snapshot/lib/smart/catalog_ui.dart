import 'dart:async';
import 'package:flutter/material.dart';
import '../legacy.dart';
import 'catalog.dart';
import 'engine.dart';

/// Full-screen local catalog. Built-in product names are Cyrillic and work
/// offline. Mixed Latin names are hidden without rewriting personal documents.
class FoodCatalogScreen extends StatefulWidget {
  final AppDataProvider provider;
  final bool pickForDiary;
  final String? nutrientFocus;
  final String? initialQuery;
  final String? initialSource;
  final Future<List<FoodItem>> Function()? loader;

  const FoodCatalogScreen({
    super.key,
    required this.provider,
    this.pickForDiary = false,
    this.nutrientFocus,
    this.initialQuery,
    this.initialSource,
    this.loader,
  });

  @override
  State<FoodCatalogScreen> createState() => _FoodCatalogScreenState();
}

class _FoodCatalogScreenState extends State<FoodCatalogScreen> {
  late final TextEditingController _search;
  Timer? _debounce;
  late Future<List<FoodItem>> _future;
  late String _query;
  String _category = FoodCatalog.allCategories;
  late String _source;
  late String _nutrient;
  late String _sort;
  bool _highProtein = false;
  bool _lowCalorie = false;
  bool _lowSugar = false;
  bool _onlineBusy = false;
  String? _onlineError;
  int _limit = 40;
  List<FoodItem> _online = const <FoodItem>[];

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.initialQuery ?? '');
    _query = widget.initialQuery ?? '';
    _source = widget.initialSource ?? FoodCatalog.allSources;
    final focus = widget.nutrientFocus;
    _nutrient = focus != null && microLabels.containsKey(focus)
        ? focus
        : FoodCatalog.anyNutrient;
    _sort = _nutrient == FoodCatalog.anyNutrient
        ? FoodCatalog.relevanceSort
        : FoodCatalog.nutrientSort;
    _future = widget.loader?.call() ?? Future.value(FoodDatabase.allFoods);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    setState(
      () {},
    ); // Rebuild the clear button immediately; results are debounced.
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() {
        _query = value;
        _limit = 40;
      });
    });
  }

  void _showProducer(String query) {
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _search.text = query;
      _query = query;
      _source = FoodCatalog.pmrSource;
      _category = FoodCatalog.allCategories;
      _sort = FoodCatalog.relevanceSort;
      _limit = 100;
    });
  }

  void _showMilkFat(String visibleLabel, String fatKey) {
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _search.text = 'Молоко $visibleLabel';
      _query = 'молоко $fatKey';
      _source = FoodCatalog.regionalSource;
      _category = FoodCatalog.allCategories;
      _sort = FoodCatalog.fatSort;
      _limit = 100;
    });
  }

  Future<void> _searchBrands() async {
    if (_onlineBusy) return;
    _debounce?.cancel();
    final query = _search.text.trim();
    setState(() => _query = query);
    if (query.length < 2) {
      setState(
        () => _onlineError = 'Введите минимум 2 символа для поиска брендов.',
      );
      return;
    }
    setState(() {
      _onlineBusy = true;
      _onlineError = null;
      // A previously selected local producer must not hide online results.
      _source = FoodCatalog.allSources;
    });
    try {
      final found = await FoodCatalog.searchOnline(query);
      if (!mounted) return;
      setState(() {
        _online = found;
        _limit = 40;
      });
      if (found.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Бренды с полными КБЖУ не найдены. Попробуйте другой запрос.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _onlineError = e is ArgumentError || e is StateError
              ? e.toString().replaceFirst(
                  RegExp(r'^(Invalid argument\(s\)|Bad state): '),
                  '',
                )
              : 'Не удалось выполнить онлайн-поиск.',
        );
      }
    } finally {
      if (mounted) setState(() => _onlineBusy = false);
    }
  }

  Future<void> _save(FoodItem food) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.provider.saveCustomFood(food);
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Продукт сохранён в «Мои продукты» — теперь он есть оффлайн.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is StateError || e is ArgumentError
                ? e.toString()
                : 'Не удалось сохранить продукт.',
          ),
        ),
      );
    }
  }

  List<FoodItem> _allFoods(List<FoodItem> embedded) {
    final seen = <String>{};
    final all = <FoodItem>[
      ...embedded,
      ...widget.provider.searchFoods(''),
      ..._online,
    ];
    return all
        .where((f) => seen.add('${f.source}|${f.name.toLowerCase()}'))
        .toList();
  }

  bool get _hasFilters =>
      _category != FoodCatalog.allCategories ||
      _source != FoodCatalog.allSources ||
      _nutrient != FoodCatalog.anyNutrient ||
      _sort != FoodCatalog.relevanceSort ||
      _highProtein ||
      _lowCalorie ||
      _lowSugar;

  void _resetFilters({bool clearSearch = true}) {
    _debounce?.cancel();
    setState(() {
      if (clearSearch) {
        _search.clear();
        _query = '';
      }
      _category = FoodCatalog.allCategories;
      _source = FoodCatalog.allSources;
      _nutrient = FoodCatalog.anyNutrient;
      _sort = FoodCatalog.relevanceSort;
      _highProtein = _lowCalorie = _lowSugar = false;
      _onlineError = null;
      _limit = 40;
    });
  }

  void _showLocalMilk() {
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _search.text = 'молоко';
      _query = 'молоко';
      _source = FoodCatalog.regionalSource;
      _category = FoodCatalog.allCategories;
      _sort = FoodCatalog.fatSort;
      _limit = 100;
    });
  }

  Future<void> _showFilters(List<String> categories) async {
    FocusScope.of(context).unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refreshSheet) {
          void update(VoidCallback action) {
            setState(action);
            refreshSheet(() {});
          }

          return SafeArea(
            child: FractionallySizedBox(
              heightFactor: .82,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Фильтры каталога',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          _resetFilters(clearSearch: false);
                          refreshSheet(() {});
                        },
                        child: const Text('Сбросить'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Категория',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  _dropdown(
                    value: _category,
                    items: categories,
                    onChanged: (v) => update(() {
                      _category = v!;
                      _limit = 40;
                    }),
                  ),
                  Text(
                    'Источник',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  _dropdown(
                    value: _source,
                    items: const [
                      FoodCatalog.allSources,
                      FoodCatalog.mySource,
                      FoodCatalog.regionalSource,
                      FoodCatalog.localSource,
                      FoodCatalog.pmrSource,
                      FoodCatalog.offSource,
                    ],
                    onChanged: (v) => update(() {
                      _source = v!;
                      _limit = 40;
                    }),
                  ),
                  Text(
                    'Нутриент',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  _dropdown(
                    value: _nutrient,
                    items: [FoodCatalog.anyNutrient, ...microLabels.keys],
                    labels: {
                      FoodCatalog.anyNutrient: FoodCatalog.anyNutrient,
                      for (final e in microLabels.entries)
                        e.key: 'Есть: ${e.value}',
                    },
                    onChanged: (v) => update(() {
                      _nutrient = v!;
                      if (_nutrient != FoodCatalog.anyNutrient)
                        _sort = FoodCatalog.nutrientSort;
                      _limit = 40;
                    }),
                  ),
                  Text(
                    'Сортировка',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  _dropdown(
                    value: _sort,
                    items: const [
                      FoodCatalog.relevanceSort,
                      FoodCatalog.proteinSort,
                      FoodCatalog.calorieSort,
                      FoodCatalog.nutrientSort,
                      FoodCatalog.fatSort,
                      FoodCatalog.nameSort,
                    ],
                    onChanged: (v) => update(() => _sort = v!),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilterChip(
                        label: const Text('Белок 20+'),
                        selected: _highProtein,
                        onSelected: (v) => update(() {
                          _highProtein = v;
                          _limit = 40;
                        }),
                      ),
                      FilterChip(
                        label: const Text('До 100 ккал'),
                        selected: _lowCalorie,
                        onSelected: (v) => update(() {
                          _lowCalorie = v;
                          _limit = 40;
                        }),
                      ),
                      FilterChip(
                        label: const Text('Сахаров ≤5 г'),
                        selected: _lowSugar,
                        onSelected: (v) => update(() {
                          _lowSugar = v;
                          _limit = 40;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Молоко по жирности',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final fat in const [
                        ('0,5%', 'fat05'),
                        ('1%', 'fat10'),
                        ('1,5%', 'fat15'),
                        ('2,5%', 'fat25'),
                        ('3,2%', 'fat32'),
                        ('3,5%', 'fat35'),
                        ('4%', 'fat40'),
                        ('6%', 'fat60'),
                      ])
                        ActionChip(
                          label: Text(fat.$1),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _showMilkFat(fat.$1, fat.$2);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  FilledButton.tonalIcon(
                    onPressed: _onlineBusy
                        ? null
                        : () {
                            Navigator.pop(sheetContext);
                            _searchBrands();
                          },
                    icon: const Icon(Icons.travel_explore_outlined),
                    label: const Text('Искать бренды онлайн'),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Для онлайн-поиска сначала введите название. Названия с латинскими буквами, включая смешанные, не показываются.',
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Показать продукты'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSources(int total) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('О каталоге'),
      content: SingleChildScrollView(
        child: Text(
          'Всего доступно $total карточек, включая сохранённые вами и загруженные онлайн. '
          'Оффлайн — продукты ПМР, местные молочные марки и знакомые бренды СНГ. '
          'Точные КБЖУ ТХК — из официального каталога; другие значения могут быть ориентировочными. Сверяйте упаковку.\n\n'
          'Онлайн-бренды: © Open Food Facts contributors, ODbL. Показываются названия с кириллицей без латинских букв.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.pickForDiary ? 'Выбрать продукт' : 'Каталог ПМР и СНГ',
        ),
        actions: [
          IconButton(
            tooltip: 'Об источниках каталога',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => _showSources(
              _allFoods(
                FoodDatabase.allFoods,
              ).where((food) => FoodCatalog.isRussianName(food.name)).length,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<FoodItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Открываем местный каталог…'),
                  ],
                ),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 42),
                      const SizedBox(height: 12),
                      const Text('Не удалось открыть местный каталог.'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => setState(() {
                          _future =
                              widget.loader?.call() ??
                              Future.value(FoodDatabase.allFoods);
                        }),
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final loaded = _allFoods(snapshot.data!);
            final all = loaded
                .where((food) => FoodCatalog.isRussianName(food.name))
                .toList();
            final hiddenCount = loaded.length - all.length;
            final categories =
                <String>{
                  FoodCatalog.allCategories,
                  ...all.map((f) => f.category),
                  _category,
                }.toList()..sort(
                  (a, b) => a == FoodCatalog.allCategories
                      ? -1
                      : b == FoodCatalog.allCategories
                      ? 1
                      : a.compareTo(b),
                );
            final results = FoodCatalog.filter(
              all,
              query: _query,
              category: _category,
              source: _source,
              nutrient: _nutrient,
              sort: _sort,
              highProtein: _highProtein,
              lowCalorie: _lowCalorie,
              lowSugar: _lowSugar,
            );
            final visible = results.take(_limit).toList();
            final hasMore = results.length > visible.length;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: _changed,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText: 'Продукт или производитель',
                            isDense: true,
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Очистить поиск',
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () {
                                      _debounce?.cancel();
                                      setState(() {
                                        _search.clear();
                                        _query = '';
                                        _limit = 40;
                                      });
                                    },
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Badge(
                        isLabelVisible: _hasFilters,
                        smallSize: 8,
                        child: IconButton.filledTonal(
                          tooltip: 'Фильтры каталога',
                          onPressed: () => _showFilters(categories),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!keyboardOpen)
                  SizedBox(
                    height: 50,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final producer in const [
                          'Вся продукция ПМР',
                          'ТХК',
                          'ТМК',
                          'БМК',
                          'Благода',
                          'Рыбницкий хлебокомбинат',
                          'Каменский консервный завод',
                          'Акватир',
                          'Квинт',
                        ]) ...[
                          ActionChip(
                            label: Text(producer),
                            onPressed: () => _showProducer(
                              producer == 'Вся продукция ПМР' ? '' : producer,
                            ),
                          ),
                          const SizedBox(width: 7),
                        ],
                        ActionChip(
                          label: const Text('Местное молоко'),
                          onPressed: _showLocalMilk,
                        ),
                      ],
                    ),
                  ),
                if (hiddenCount > 0 && !keyboardOpen)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Названия в каталоге'),
                            content: const Text(
                              'Названия с латинскими буквами не показываются в '
                              'каталоге и поиске. Личные записи и избранное '
                              'не удалены. Свои продукты можно переименовать '
                              'в «Настройки → Своя база продуктов».',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Понятно'),
                              ),
                            ],
                          ),
                        ),
                        icon: const Icon(Icons.info_outline, size: 16),
                        label: Text('Скрыто названий: $hiddenCount'),
                      ),
                    ),
                  ),
                if (_onlineError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(
                      _onlineError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 3, 12, 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Найдено ${results.length} · всего ${all.length}',
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                      if (_onlineBusy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (_online.isNotEmpty)
                        TextButton(
                          onPressed: () => setState(() {
                            _online = const [];
                            _onlineError = null;
                          }),
                          child: const Text('Скрыть онлайн'),
                        ),
                      if (_hasFilters)
                        IconButton(
                          tooltip: 'Сбросить фильтры',
                          onPressed: () => _resetFilters(clearSearch: false),
                          icon: const Icon(
                            Icons.filter_alt_off_outlined,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: results.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.search_off_rounded,
                                    size: 36,
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Ничего не найдено. Попробуйте другое название или снимите фильтры.',
                                    textAlign: TextAlign.center,
                                  ),
                                  TextButton(
                                    onPressed: _resetFilters,
                                    child: const Text('Сбросить всё'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          itemCount: visible.length + (hasMore ? 1 : 0),
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            if (index == visible.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: OutlinedButton(
                                  onPressed: () => setState(() => _limit += 40),
                                  child: Text(
                                    'Показать ещё · осталось ${results.length - visible.length}',
                                  ),
                                ),
                              );
                            }
                            final food = visible[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              title: Text(
                                food.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${food.calories.round()} ккал · Б ${formatGrams(food.protein)} '
                                'Ж ${formatGrams(food.fat)} У ${formatGrams(food.carbs)} / 100 г\n'
                                '${food.source} · ${food.category}${food.brand == null ? '' : ' · ${food.brand}'}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall,
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                tooltip: 'Сохранить в «Мои продукты»',
                                icon: const Icon(Icons.bookmark_add_outlined),
                                onPressed: () => _save(food),
                              ),
                              onTap: () {
                                if (widget.pickForDiary) {
                                  Navigator.pop(context, food);
                                } else {
                                  _details(food);
                                }
                              },
                            );
                          },
                        ),
                ),
                if (!keyboardOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 3, 16, 7),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'КБЖУ сверяйте с упаковкой · ⓘ источники вверху',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _dropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    Map<String, String>? labels,
  }) => SizedBox(
    height: 48,
    child: DropdownButton<String>(
      value: items.contains(value) ? value : items.first,
      isExpanded: true,
      items: [
        for (final item in items.toSet())
          DropdownMenuItem(
            value: item,
            child: Text(
              labels?[item] ?? item,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    ),
  );

  Future<void> _details(FoodItem food) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .65,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            Text(food.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('${food.source} · ${food.category}'),
            if (food.brand != null && food.brand!.isNotEmpty)
              Text('Бренд: ${food.brand}'),
            if (food.barcode != null && food.barcode!.isNotEmpty)
              Text('Штрихкод: ${food.barcode}'),
            if (food.note != null && food.note!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(food.note!, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (food.sourceUrl != null && food.sourceUrl!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Источник: ${food.sourceUrl}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'На 100 г: ${food.calories.round()} ккал · '
              'Б ${formatGrams(food.protein)} Ж ${formatGrams(food.fat)} У ${formatGrams(food.carbs)}',
            ),
            const SizedBox(height: 14),
            Text(
              'Известные витамины и минералы',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (food.micros.isEmpty)
              const Text(
                'Источник не сообщает значения микронутриентов. Это не значит, что их нет.',
              )
            else
              for (final e in food.micros.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(microLabels[e.key] ?? e.key),
                  trailing: Text('${formatNutrient(e.value)} / 100 г'),
                ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _save(food);
              },
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('В «Мои продукты»'),
            ),
            if (widget.pickForDiary) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context, food);
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Выбрать порцию'),
              ),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
