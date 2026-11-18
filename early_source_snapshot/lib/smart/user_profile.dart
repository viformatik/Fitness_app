// Reconstructed after the workspace snapshot dropped the prior tested model.
// This source is NOT byte-identical to +40 and must be retested independently.
// Missing or legacy values are not user-confirmed goals. A confirmation from
// storage is accepted only when its saved snapshot exactly matches the value.
class UserProfile {
  final int? ageYears;
  final double height;
  final double currentWeight;
  final double targetWeight;
  final bool? heightConfirmed;
  final bool? currentWeightConfirmed;
  final bool? targetWeightConfirmed;

  final int? dailyCaloriesMin;
  final int? dailyCaloriesMax;
  final int? targetProtein;
  final int? targetFat;
  final int? targetCarbs;
  final int? dailyStepsGoal;
  final int? dailyWaterGoalMl;
  final bool calorieGoalConfirmed;
  final bool proteinGoalConfirmed;
  final bool fatGoalConfirmed;
  final bool carbsGoalConfirmed;
  final bool stepsGoalConfirmed;
  final bool waterGoalConfirmed;

  // These historical workout settings are not measurements or recommended
  // individual values. The workout entry editor separately requires input.
  final int workoutsPerWeek;
  final int strengthDurationMinutes;
  final int cardioDurationMinutes;
  final int workoutCaloriesBurned;

  const UserProfile({
    this.ageYears,
    this.height = 175,
    this.currentWeight = 85.9,
    this.targetWeight = 75,
    this.heightConfirmed = false,
    this.currentWeightConfirmed = false,
    this.targetWeightConfirmed = false,
    this.dailyCaloriesMin,
    this.dailyCaloriesMax,
    this.targetProtein,
    this.targetFat,
    this.targetCarbs,
    this.dailyStepsGoal,
    this.dailyWaterGoalMl,
    this.calorieGoalConfirmed = false,
    this.proteinGoalConfirmed = false,
    this.fatGoalConfirmed = false,
    this.carbsGoalConfirmed = false,
    this.stepsGoalConfirmed = false,
    this.waterGoalConfirmed = false,
    this.workoutsPerWeek = 4,
    this.strengthDurationMinutes = 40,
    this.cardioDurationMinutes = 30,
    this.workoutCaloriesBurned = 500,
  });

  bool get hasConfirmedCalorieGoal =>
      calorieGoalConfirmed &&
      dailyCaloriesMin != null &&
      dailyCaloriesMax != null &&
      dailyCaloriesMin! >= 0 &&
      dailyCaloriesMax! >= dailyCaloriesMin!;
  bool get hasConfirmedProteinGoal =>
      proteinGoalConfirmed && targetProtein != null && targetProtein! >= 0;
  bool get hasConfirmedFatGoal =>
      fatGoalConfirmed && targetFat != null && targetFat! >= 0;
  bool get hasConfirmedCarbsGoal =>
      carbsGoalConfirmed && targetCarbs != null && targetCarbs! >= 0;
  bool get hasConfirmedStepsGoal =>
      stepsGoalConfirmed && dailyStepsGoal != null && dailyStepsGoal! > 0;
  bool get hasConfirmedWaterGoal =>
      waterGoalConfirmed && dailyWaterGoalMl != null && dailyWaterGoalMl! > 0;
  int? get dailyCaloriesTarget => hasConfirmedCalorieGoal
      ? (dailyCaloriesMin! + dailyCaloriesMax!) ~/ 2
      : null;

  static int? _readAge(Object? value) {
    if (value == null) return null;
    if (value is int && value >= 1 && value <= 120) return value;
    throw const FormatException(
      'Возраст должен быть целым числом от 1 до 120.',
    );
  }

  static bool? _measurementConfirmed(
    Map<String, dynamic> json,
    String valueKey,
    String flagKey,
  ) {
    final value = json[valueKey];
    if (value is! num || !value.isFinite || value <= 0) return false;
    return json[flagKey] as bool?;
  }

  static bool _confirmedValue(
    Map<String, dynamic> json,
    String flag,
    String value,
    String snapshot, {
    bool strictlyPositive = false,
  }) {
    final n = json[value];
    return json[flag] == true &&
        n is int &&
        (strictlyPositive ? n > 0 : n >= 0) &&
        json[snapshot] is int &&
        json[snapshot] == n;
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final lo = json['dailyCaloriesMin'] as int?;
    final hi = json['dailyCaloriesMax'] as int?;
    final confirmedCalories =
        json['calorieGoalConfirmed'] == true &&
        lo != null &&
        hi != null &&
        lo >= 0 &&
        hi >= lo &&
        json['calorieGoalConfirmedMin'] is int &&
        json['calorieGoalConfirmedMax'] is int &&
        json['calorieGoalConfirmedMin'] == lo &&
        json['calorieGoalConfirmedMax'] == hi;
    return UserProfile(
      ageYears: _readAge(json['ageYears']),
      height: (json['height'] as num?)?.toDouble() ?? 175,
      currentWeight: (json['currentWeight'] as num?)?.toDouble() ?? 85.9,
      targetWeight: (json['targetWeight'] as num?)?.toDouble() ?? 75,
      heightConfirmed: _measurementConfirmed(json, 'height', 'heightConfirmed'),
      currentWeightConfirmed: _measurementConfirmed(
        json,
        'currentWeight',
        'currentWeightConfirmed',
      ),
      targetWeightConfirmed: _measurementConfirmed(
        json,
        'targetWeight',
        'targetWeightConfirmed',
      ),
      dailyCaloriesMin: lo,
      dailyCaloriesMax: hi,
      targetProtein: json['targetProtein'] as int?,
      targetFat: json['targetFat'] as int?,
      targetCarbs: json['targetCarbs'] as int?,
      dailyStepsGoal: json['dailyStepsGoal'] as int?,
      dailyWaterGoalMl: json['dailyWaterGoalMl'] as int?,
      calorieGoalConfirmed: confirmedCalories,
      proteinGoalConfirmed: _confirmedValue(
        json,
        'proteinGoalConfirmed',
        'targetProtein',
        'proteinGoalConfirmedValue',
      ),
      fatGoalConfirmed: _confirmedValue(
        json,
        'fatGoalConfirmed',
        'targetFat',
        'fatGoalConfirmedValue',
      ),
      carbsGoalConfirmed: _confirmedValue(
        json,
        'carbsGoalConfirmed',
        'targetCarbs',
        'carbsGoalConfirmedValue',
      ),
      stepsGoalConfirmed: _confirmedValue(
        json,
        'stepsGoalConfirmed',
        'dailyStepsGoal',
        'stepsGoalConfirmedValue',
        strictlyPositive: true,
      ),
      waterGoalConfirmed: _confirmedValue(
        json,
        'waterGoalConfirmed',
        'dailyWaterGoalMl',
        'waterGoalConfirmedValue',
        strictlyPositive: true,
      ),
      workoutsPerWeek: json['workoutsPerWeek'] as int? ?? 4,
      strengthDurationMinutes: json['strengthDurationMinutes'] as int? ?? 40,
      cardioDurationMinutes: json['cardioDurationMinutes'] as int? ?? 30,
      workoutCaloriesBurned: json['workoutCaloriesBurned'] as int? ?? 500,
    );
  }

  Map<String, dynamic> toJson() => {
    // Null is explicit so a compatible cloud writer can distinguish an
    // age removal from an old client that does not know this field.
    'ageYears': ageYears,
    'height': height,
    'currentWeight': currentWeight,
    'targetWeight': targetWeight,
    if (heightConfirmed != null) 'heightConfirmed': heightConfirmed,
    if (currentWeightConfirmed != null)
      'currentWeightConfirmed': currentWeightConfirmed,
    if (targetWeightConfirmed != null)
      'targetWeightConfirmed': targetWeightConfirmed,
    if (dailyCaloriesMin != null) 'dailyCaloriesMin': dailyCaloriesMin,
    if (dailyCaloriesMax != null) 'dailyCaloriesMax': dailyCaloriesMax,
    if (targetProtein != null) 'targetProtein': targetProtein,
    if (targetFat != null) 'targetFat': targetFat,
    if (targetCarbs != null) 'targetCarbs': targetCarbs,
    if (dailyStepsGoal != null) 'dailyStepsGoal': dailyStepsGoal,
    if (dailyWaterGoalMl != null) 'dailyWaterGoalMl': dailyWaterGoalMl,
    'calorieGoalConfirmed': hasConfirmedCalorieGoal,
    'proteinGoalConfirmed': hasConfirmedProteinGoal,
    'fatGoalConfirmed': hasConfirmedFatGoal,
    'carbsGoalConfirmed': hasConfirmedCarbsGoal,
    'stepsGoalConfirmed': hasConfirmedStepsGoal,
    'waterGoalConfirmed': hasConfirmedWaterGoal,
    if (hasConfirmedCalorieGoal) ...{
      'calorieGoalConfirmedMin': dailyCaloriesMin,
      'calorieGoalConfirmedMax': dailyCaloriesMax,
    },
    if (hasConfirmedProteinGoal) 'proteinGoalConfirmedValue': targetProtein,
    if (hasConfirmedFatGoal) 'fatGoalConfirmedValue': targetFat,
    if (hasConfirmedCarbsGoal) 'carbsGoalConfirmedValue': targetCarbs,
    if (hasConfirmedStepsGoal) 'stepsGoalConfirmedValue': dailyStepsGoal,
    if (hasConfirmedWaterGoal) 'waterGoalConfirmedValue': dailyWaterGoalMl,
    'workoutsPerWeek': workoutsPerWeek,
    'strengthDurationMinutes': strengthDurationMinutes,
    'cardioDurationMinutes': cardioDurationMinutes,
    'workoutCaloriesBurned': workoutCaloriesBurned,
  };

  UserProfile copyWith({
    int? ageYears,
    bool clearAge = false,
    double? height,
    double? currentWeight,
    double? targetWeight,
    bool? heightConfirmed,
    bool? currentWeightConfirmed,
    bool? targetWeightConfirmed,
    int? dailyCaloriesMin,
    int? dailyCaloriesMax,
    int? targetProtein,
    int? targetFat,
    int? targetCarbs,
    int? dailyStepsGoal,
    int? dailyWaterGoalMl,
    bool? calorieGoalConfirmed,
    bool? proteinGoalConfirmed,
    bool? fatGoalConfirmed,
    bool? carbsGoalConfirmed,
    bool? stepsGoalConfirmed,
    bool? waterGoalConfirmed,
    int? workoutsPerWeek,
    int? strengthDurationMinutes,
    int? cardioDurationMinutes,
    int? workoutCaloriesBurned,
  }) => UserProfile(
    ageYears: clearAge ? null : (ageYears ?? this.ageYears),
    height: height ?? this.height,
    currentWeight: currentWeight ?? this.currentWeight,
    targetWeight: targetWeight ?? this.targetWeight,
    heightConfirmed:
        heightConfirmed ?? (height != null ? true : this.heightConfirmed),
    currentWeightConfirmed:
        currentWeightConfirmed ??
        (currentWeight != null ? true : this.currentWeightConfirmed),
    targetWeightConfirmed:
        targetWeightConfirmed ??
        (targetWeight != null ? true : this.targetWeightConfirmed),
    dailyCaloriesMin: dailyCaloriesMin ?? this.dailyCaloriesMin,
    dailyCaloriesMax: dailyCaloriesMax ?? this.dailyCaloriesMax,
    targetProtein: targetProtein ?? this.targetProtein,
    targetFat: targetFat ?? this.targetFat,
    targetCarbs: targetCarbs ?? this.targetCarbs,
    dailyStepsGoal: dailyStepsGoal ?? this.dailyStepsGoal,
    dailyWaterGoalMl: dailyWaterGoalMl ?? this.dailyWaterGoalMl,
    // A corridor is confirmed only when both bounds were reviewed in the
    // same edit. A partial edit invalidates, never silently reauthorizes.
    calorieGoalConfirmed:
        calorieGoalConfirmed ??
        ((dailyCaloriesMin != null || dailyCaloriesMax != null)
            ? dailyCaloriesMin != null && dailyCaloriesMax != null
            : hasConfirmedCalorieGoal),
    proteinGoalConfirmed:
        proteinGoalConfirmed ??
        (targetProtein != null ? true : hasConfirmedProteinGoal),
    fatGoalConfirmed:
        fatGoalConfirmed ?? (targetFat != null ? true : hasConfirmedFatGoal),
    carbsGoalConfirmed:
        carbsGoalConfirmed ??
        (targetCarbs != null ? true : hasConfirmedCarbsGoal),
    stepsGoalConfirmed:
        stepsGoalConfirmed ??
        (dailyStepsGoal != null ? true : hasConfirmedStepsGoal),
    waterGoalConfirmed:
        waterGoalConfirmed ??
        (dailyWaterGoalMl != null ? true : hasConfirmedWaterGoal),
    workoutsPerWeek: workoutsPerWeek ?? this.workoutsPerWeek,
    strengthDurationMinutes:
        strengthDurationMinutes ?? this.strengthDurationMinutes,
    cardioDurationMinutes: cardioDurationMinutes ?? this.cardioDurationMinutes,
    workoutCaloriesBurned: workoutCaloriesBurned ?? this.workoutCaloriesBurned,
  );
}
