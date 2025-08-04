class Input$CreateShareLinkInput {
  factory Input$CreateShareLinkInput({
    required String anonymous_id,
    String? first_name,
    String? last_name,
    String? email,
  }) =>
      Input$CreateShareLinkInput._({
        r'anonymous_id': anonymous_id,
        if (first_name != null) r'first_name': first_name,
        if (last_name != null) r'last_name': last_name,
        if (email != null) r'email': email,
      });

  Input$CreateShareLinkInput._(this._$data);

  factory Input$CreateShareLinkInput.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$anonymous_id = data['anonymous_id'];
    result$data['anonymous_id'] = (l$anonymous_id as String);
    if (data.containsKey('first_name')) {
      final l$first_name = data['first_name'];
      result$data['first_name'] = (l$first_name as String?);
    }
    if (data.containsKey('last_name')) {
      final l$last_name = data['last_name'];
      result$data['last_name'] = (l$last_name as String?);
    }
    if (data.containsKey('email')) {
      final l$email = data['email'];
      result$data['email'] = (l$email as String?);
    }
    return Input$CreateShareLinkInput._(result$data);
  }

  Map<String, dynamic> _$data;

  String get anonymous_id => (_$data['anonymous_id'] as String);

  String? get first_name => (_$data['first_name'] as String?);

  String? get last_name => (_$data['last_name'] as String?);

  String? get email => (_$data['email'] as String?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$anonymous_id = anonymous_id;
    result$data['anonymous_id'] = l$anonymous_id;
    if (_$data.containsKey('first_name')) {
      final l$first_name = first_name;
      result$data['first_name'] = l$first_name;
    }
    if (_$data.containsKey('last_name')) {
      final l$last_name = last_name;
      result$data['last_name'] = l$last_name;
    }
    if (_$data.containsKey('email')) {
      final l$email = email;
      result$data['email'] = l$email;
    }
    return result$data;
  }

  CopyWith$Input$CreateShareLinkInput<Input$CreateShareLinkInput>
      get copyWith => CopyWith$Input$CreateShareLinkInput(
            this,
            (i) => i,
          );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Input$CreateShareLinkInput) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$anonymous_id = anonymous_id;
    final lOther$anonymous_id = other.anonymous_id;
    if (l$anonymous_id != lOther$anonymous_id) {
      return false;
    }
    final l$first_name = first_name;
    final lOther$first_name = other.first_name;
    if (_$data.containsKey('first_name') !=
        other._$data.containsKey('first_name')) {
      return false;
    }
    if (l$first_name != lOther$first_name) {
      return false;
    }
    final l$last_name = last_name;
    final lOther$last_name = other.last_name;
    if (_$data.containsKey('last_name') !=
        other._$data.containsKey('last_name')) {
      return false;
    }
    if (l$last_name != lOther$last_name) {
      return false;
    }
    final l$email = email;
    final lOther$email = other.email;
    if (_$data.containsKey('email') != other._$data.containsKey('email')) {
      return false;
    }
    if (l$email != lOther$email) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$anonymous_id = anonymous_id;
    final l$first_name = first_name;
    final l$last_name = last_name;
    final l$email = email;
    return Object.hashAll([
      l$anonymous_id,
      _$data.containsKey('first_name') ? l$first_name : const {},
      _$data.containsKey('last_name') ? l$last_name : const {},
      _$data.containsKey('email') ? l$email : const {},
    ]);
  }
}

abstract class CopyWith$Input$CreateShareLinkInput<TRes> {
  factory CopyWith$Input$CreateShareLinkInput(
    Input$CreateShareLinkInput instance,
    TRes Function(Input$CreateShareLinkInput) then,
  ) = _CopyWithImpl$Input$CreateShareLinkInput;

  factory CopyWith$Input$CreateShareLinkInput.stub(TRes res) =
      _CopyWithStubImpl$Input$CreateShareLinkInput;

  TRes call({
    String? anonymous_id,
    String? first_name,
    String? last_name,
    String? email,
  });
}

class _CopyWithImpl$Input$CreateShareLinkInput<TRes>
    implements CopyWith$Input$CreateShareLinkInput<TRes> {
  _CopyWithImpl$Input$CreateShareLinkInput(
    this._instance,
    this._then,
  );

  final Input$CreateShareLinkInput _instance;

  final TRes Function(Input$CreateShareLinkInput) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? anonymous_id = _undefined,
    Object? first_name = _undefined,
    Object? last_name = _undefined,
    Object? email = _undefined,
  }) =>
      _then(Input$CreateShareLinkInput._({
        ..._instance._$data,
        if (anonymous_id != _undefined && anonymous_id != null)
          'anonymous_id': (anonymous_id as String),
        if (first_name != _undefined) 'first_name': (first_name as String?),
        if (last_name != _undefined) 'last_name': (last_name as String?),
        if (email != _undefined) 'email': (email as String?),
      }));
}

class _CopyWithStubImpl$Input$CreateShareLinkInput<TRes>
    implements CopyWith$Input$CreateShareLinkInput<TRes> {
  _CopyWithStubImpl$Input$CreateShareLinkInput(this._res);

  TRes _res;

  call({
    String? anonymous_id,
    String? first_name,
    String? last_name,
    String? email,
  }) =>
      _res;
}

class Input$ListeningEventInput {
  factory Input$ListeningEventInput({
    required String anonymous_session_id,
    required String station_slug,
    required String ip_address,
    required String user_agent,
    required String timestamp,
    required String event_type,
    required int bytes_transferred,
    required double request_duration,
    required int status_code,
    int? request_count,
  }) =>
      Input$ListeningEventInput._({
        r'anonymous_session_id': anonymous_session_id,
        r'station_slug': station_slug,
        r'ip_address': ip_address,
        r'user_agent': user_agent,
        r'timestamp': timestamp,
        r'event_type': event_type,
        r'bytes_transferred': bytes_transferred,
        r'request_duration': request_duration,
        r'status_code': status_code,
        if (request_count != null) r'request_count': request_count,
      });

  Input$ListeningEventInput._(this._$data);

  factory Input$ListeningEventInput.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$anonymous_session_id = data['anonymous_session_id'];
    result$data['anonymous_session_id'] = (l$anonymous_session_id as String);
    final l$station_slug = data['station_slug'];
    result$data['station_slug'] = (l$station_slug as String);
    final l$ip_address = data['ip_address'];
    result$data['ip_address'] = (l$ip_address as String);
    final l$user_agent = data['user_agent'];
    result$data['user_agent'] = (l$user_agent as String);
    final l$timestamp = data['timestamp'];
    result$data['timestamp'] = (l$timestamp as String);
    final l$event_type = data['event_type'];
    result$data['event_type'] = (l$event_type as String);
    final l$bytes_transferred = data['bytes_transferred'];
    result$data['bytes_transferred'] = (l$bytes_transferred as int);
    final l$request_duration = data['request_duration'];
    result$data['request_duration'] = (l$request_duration as num).toDouble();
    final l$status_code = data['status_code'];
    result$data['status_code'] = (l$status_code as int);
    if (data.containsKey('request_count')) {
      final l$request_count = data['request_count'];
      result$data['request_count'] = (l$request_count as int?);
    }
    return Input$ListeningEventInput._(result$data);
  }

  Map<String, dynamic> _$data;

  String get anonymous_session_id => (_$data['anonymous_session_id'] as String);

  String get station_slug => (_$data['station_slug'] as String);

  String get ip_address => (_$data['ip_address'] as String);

  String get user_agent => (_$data['user_agent'] as String);

  String get timestamp => (_$data['timestamp'] as String);

  String get event_type => (_$data['event_type'] as String);

  int get bytes_transferred => (_$data['bytes_transferred'] as int);

  double get request_duration => (_$data['request_duration'] as double);

  int get status_code => (_$data['status_code'] as int);

  int? get request_count => (_$data['request_count'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$anonymous_session_id = anonymous_session_id;
    result$data['anonymous_session_id'] = l$anonymous_session_id;
    final l$station_slug = station_slug;
    result$data['station_slug'] = l$station_slug;
    final l$ip_address = ip_address;
    result$data['ip_address'] = l$ip_address;
    final l$user_agent = user_agent;
    result$data['user_agent'] = l$user_agent;
    final l$timestamp = timestamp;
    result$data['timestamp'] = l$timestamp;
    final l$event_type = event_type;
    result$data['event_type'] = l$event_type;
    final l$bytes_transferred = bytes_transferred;
    result$data['bytes_transferred'] = l$bytes_transferred;
    final l$request_duration = request_duration;
    result$data['request_duration'] = l$request_duration;
    final l$status_code = status_code;
    result$data['status_code'] = l$status_code;
    if (_$data.containsKey('request_count')) {
      final l$request_count = request_count;
      result$data['request_count'] = l$request_count;
    }
    return result$data;
  }

  CopyWith$Input$ListeningEventInput<Input$ListeningEventInput> get copyWith =>
      CopyWith$Input$ListeningEventInput(
        this,
        (i) => i,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Input$ListeningEventInput) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$anonymous_session_id = anonymous_session_id;
    final lOther$anonymous_session_id = other.anonymous_session_id;
    if (l$anonymous_session_id != lOther$anonymous_session_id) {
      return false;
    }
    final l$station_slug = station_slug;
    final lOther$station_slug = other.station_slug;
    if (l$station_slug != lOther$station_slug) {
      return false;
    }
    final l$ip_address = ip_address;
    final lOther$ip_address = other.ip_address;
    if (l$ip_address != lOther$ip_address) {
      return false;
    }
    final l$user_agent = user_agent;
    final lOther$user_agent = other.user_agent;
    if (l$user_agent != lOther$user_agent) {
      return false;
    }
    final l$timestamp = timestamp;
    final lOther$timestamp = other.timestamp;
    if (l$timestamp != lOther$timestamp) {
      return false;
    }
    final l$event_type = event_type;
    final lOther$event_type = other.event_type;
    if (l$event_type != lOther$event_type) {
      return false;
    }
    final l$bytes_transferred = bytes_transferred;
    final lOther$bytes_transferred = other.bytes_transferred;
    if (l$bytes_transferred != lOther$bytes_transferred) {
      return false;
    }
    final l$request_duration = request_duration;
    final lOther$request_duration = other.request_duration;
    if (l$request_duration != lOther$request_duration) {
      return false;
    }
    final l$status_code = status_code;
    final lOther$status_code = other.status_code;
    if (l$status_code != lOther$status_code) {
      return false;
    }
    final l$request_count = request_count;
    final lOther$request_count = other.request_count;
    if (_$data.containsKey('request_count') !=
        other._$data.containsKey('request_count')) {
      return false;
    }
    if (l$request_count != lOther$request_count) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$anonymous_session_id = anonymous_session_id;
    final l$station_slug = station_slug;
    final l$ip_address = ip_address;
    final l$user_agent = user_agent;
    final l$timestamp = timestamp;
    final l$event_type = event_type;
    final l$bytes_transferred = bytes_transferred;
    final l$request_duration = request_duration;
    final l$status_code = status_code;
    final l$request_count = request_count;
    return Object.hashAll([
      l$anonymous_session_id,
      l$station_slug,
      l$ip_address,
      l$user_agent,
      l$timestamp,
      l$event_type,
      l$bytes_transferred,
      l$request_duration,
      l$status_code,
      _$data.containsKey('request_count') ? l$request_count : const {},
    ]);
  }
}

abstract class CopyWith$Input$ListeningEventInput<TRes> {
  factory CopyWith$Input$ListeningEventInput(
    Input$ListeningEventInput instance,
    TRes Function(Input$ListeningEventInput) then,
  ) = _CopyWithImpl$Input$ListeningEventInput;

  factory CopyWith$Input$ListeningEventInput.stub(TRes res) =
      _CopyWithStubImpl$Input$ListeningEventInput;

  TRes call({
    String? anonymous_session_id,
    String? station_slug,
    String? ip_address,
    String? user_agent,
    String? timestamp,
    String? event_type,
    int? bytes_transferred,
    double? request_duration,
    int? status_code,
    int? request_count,
  });
}

class _CopyWithImpl$Input$ListeningEventInput<TRes>
    implements CopyWith$Input$ListeningEventInput<TRes> {
  _CopyWithImpl$Input$ListeningEventInput(
    this._instance,
    this._then,
  );

  final Input$ListeningEventInput _instance;

  final TRes Function(Input$ListeningEventInput) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? anonymous_session_id = _undefined,
    Object? station_slug = _undefined,
    Object? ip_address = _undefined,
    Object? user_agent = _undefined,
    Object? timestamp = _undefined,
    Object? event_type = _undefined,
    Object? bytes_transferred = _undefined,
    Object? request_duration = _undefined,
    Object? status_code = _undefined,
    Object? request_count = _undefined,
  }) =>
      _then(Input$ListeningEventInput._({
        ..._instance._$data,
        if (anonymous_session_id != _undefined && anonymous_session_id != null)
          'anonymous_session_id': (anonymous_session_id as String),
        if (station_slug != _undefined && station_slug != null)
          'station_slug': (station_slug as String),
        if (ip_address != _undefined && ip_address != null)
          'ip_address': (ip_address as String),
        if (user_agent != _undefined && user_agent != null)
          'user_agent': (user_agent as String),
        if (timestamp != _undefined && timestamp != null)
          'timestamp': (timestamp as String),
        if (event_type != _undefined && event_type != null)
          'event_type': (event_type as String),
        if (bytes_transferred != _undefined && bytes_transferred != null)
          'bytes_transferred': (bytes_transferred as int),
        if (request_duration != _undefined && request_duration != null)
          'request_duration': (request_duration as double),
        if (status_code != _undefined && status_code != null)
          'status_code': (status_code as int),
        if (request_count != _undefined)
          'request_count': (request_count as int?),
      }));
}

class _CopyWithStubImpl$Input$ListeningEventInput<TRes>
    implements CopyWith$Input$ListeningEventInput<TRes> {
  _CopyWithStubImpl$Input$ListeningEventInput(this._res);

  TRes _res;

  call({
    String? anonymous_session_id,
    String? station_slug,
    String? ip_address,
    String? user_agent,
    String? timestamp,
    String? event_type,
    int? bytes_transferred,
    double? request_duration,
    int? status_code,
    int? request_count,
  }) =>
      _res;
}

class Input$PostOrderBy {
  factory Input$PostOrderBy({Enum$OrderDirection? published}) =>
      Input$PostOrderBy._({
        if (published != null) r'published': published,
      });

  Input$PostOrderBy._(this._$data);

  factory Input$PostOrderBy.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    if (data.containsKey('published')) {
      final l$published = data['published'];
      result$data['published'] = l$published == null
          ? null
          : fromJson$Enum$OrderDirection((l$published as String));
    }
    return Input$PostOrderBy._(result$data);
  }

  Map<String, dynamic> _$data;

  Enum$OrderDirection? get published =>
      (_$data['published'] as Enum$OrderDirection?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    if (_$data.containsKey('published')) {
      final l$published = published;
      result$data['published'] =
          l$published == null ? null : toJson$Enum$OrderDirection(l$published);
    }
    return result$data;
  }

  CopyWith$Input$PostOrderBy<Input$PostOrderBy> get copyWith =>
      CopyWith$Input$PostOrderBy(
        this,
        (i) => i,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Input$PostOrderBy) || runtimeType != other.runtimeType) {
      return false;
    }
    final l$published = published;
    final lOther$published = other.published;
    if (_$data.containsKey('published') !=
        other._$data.containsKey('published')) {
      return false;
    }
    if (l$published != lOther$published) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$published = published;
    return Object.hashAll(
        [_$data.containsKey('published') ? l$published : const {}]);
  }
}

abstract class CopyWith$Input$PostOrderBy<TRes> {
  factory CopyWith$Input$PostOrderBy(
    Input$PostOrderBy instance,
    TRes Function(Input$PostOrderBy) then,
  ) = _CopyWithImpl$Input$PostOrderBy;

  factory CopyWith$Input$PostOrderBy.stub(TRes res) =
      _CopyWithStubImpl$Input$PostOrderBy;

  TRes call({Enum$OrderDirection? published});
}

class _CopyWithImpl$Input$PostOrderBy<TRes>
    implements CopyWith$Input$PostOrderBy<TRes> {
  _CopyWithImpl$Input$PostOrderBy(
    this._instance,
    this._then,
  );

  final Input$PostOrderBy _instance;

  final TRes Function(Input$PostOrderBy) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? published = _undefined}) => _then(Input$PostOrderBy._({
        ..._instance._$data,
        if (published != _undefined)
          'published': (published as Enum$OrderDirection?),
      }));
}

class _CopyWithStubImpl$Input$PostOrderBy<TRes>
    implements CopyWith$Input$PostOrderBy<TRes> {
  _CopyWithStubImpl$Input$PostOrderBy(this._res);

  TRes _res;

  call({Enum$OrderDirection? published}) => _res;
}

class Input$StationOrderBy {
  factory Input$StationOrderBy({
    Enum$OrderDirection? order,
    Enum$OrderDirection? title,
  }) =>
      Input$StationOrderBy._({
        if (order != null) r'order': order,
        if (title != null) r'title': title,
      });

  Input$StationOrderBy._(this._$data);

  factory Input$StationOrderBy.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    if (data.containsKey('order')) {
      final l$order = data['order'];
      result$data['order'] = l$order == null
          ? null
          : fromJson$Enum$OrderDirection((l$order as String));
    }
    if (data.containsKey('title')) {
      final l$title = data['title'];
      result$data['title'] = l$title == null
          ? null
          : fromJson$Enum$OrderDirection((l$title as String));
    }
    return Input$StationOrderBy._(result$data);
  }

  Map<String, dynamic> _$data;

  Enum$OrderDirection? get order => (_$data['order'] as Enum$OrderDirection?);

  Enum$OrderDirection? get title => (_$data['title'] as Enum$OrderDirection?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    if (_$data.containsKey('order')) {
      final l$order = order;
      result$data['order'] =
          l$order == null ? null : toJson$Enum$OrderDirection(l$order);
    }
    if (_$data.containsKey('title')) {
      final l$title = title;
      result$data['title'] =
          l$title == null ? null : toJson$Enum$OrderDirection(l$title);
    }
    return result$data;
  }

  CopyWith$Input$StationOrderBy<Input$StationOrderBy> get copyWith =>
      CopyWith$Input$StationOrderBy(
        this,
        (i) => i,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Input$StationOrderBy) || runtimeType != other.runtimeType) {
      return false;
    }
    final l$order = order;
    final lOther$order = other.order;
    if (_$data.containsKey('order') != other._$data.containsKey('order')) {
      return false;
    }
    if (l$order != lOther$order) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (_$data.containsKey('title') != other._$data.containsKey('title')) {
      return false;
    }
    if (l$title != lOther$title) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$order = order;
    final l$title = title;
    return Object.hashAll([
      _$data.containsKey('order') ? l$order : const {},
      _$data.containsKey('title') ? l$title : const {},
    ]);
  }
}

abstract class CopyWith$Input$StationOrderBy<TRes> {
  factory CopyWith$Input$StationOrderBy(
    Input$StationOrderBy instance,
    TRes Function(Input$StationOrderBy) then,
  ) = _CopyWithImpl$Input$StationOrderBy;

  factory CopyWith$Input$StationOrderBy.stub(TRes res) =
      _CopyWithStubImpl$Input$StationOrderBy;

  TRes call({
    Enum$OrderDirection? order,
    Enum$OrderDirection? title,
  });
}

class _CopyWithImpl$Input$StationOrderBy<TRes>
    implements CopyWith$Input$StationOrderBy<TRes> {
  _CopyWithImpl$Input$StationOrderBy(
    this._instance,
    this._then,
  );

  final Input$StationOrderBy _instance;

  final TRes Function(Input$StationOrderBy) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? order = _undefined,
    Object? title = _undefined,
  }) =>
      _then(Input$StationOrderBy._({
        ..._instance._$data,
        if (order != _undefined) 'order': (order as Enum$OrderDirection?),
        if (title != _undefined) 'title': (title as Enum$OrderDirection?),
      }));
}

class _CopyWithStubImpl$Input$StationOrderBy<TRes>
    implements CopyWith$Input$StationOrderBy<TRes> {
  _CopyWithStubImpl$Input$StationOrderBy(this._res);

  TRes _res;

  call({
    Enum$OrderDirection? order,
    Enum$OrderDirection? title,
  }) =>
      _res;
}

enum Enum$OperationMessageKind {
  INFO,
  WARNING,
  ERROR,
  PERMISSION,
  VALIDATION,
  $unknown;

  factory Enum$OperationMessageKind.fromJson(String value) =>
      fromJson$Enum$OperationMessageKind(value);

  String toJson() => toJson$Enum$OperationMessageKind(this);
}

String toJson$Enum$OperationMessageKind(Enum$OperationMessageKind e) {
  switch (e) {
    case Enum$OperationMessageKind.INFO:
      return r'INFO';
    case Enum$OperationMessageKind.WARNING:
      return r'WARNING';
    case Enum$OperationMessageKind.ERROR:
      return r'ERROR';
    case Enum$OperationMessageKind.PERMISSION:
      return r'PERMISSION';
    case Enum$OperationMessageKind.VALIDATION:
      return r'VALIDATION';
    case Enum$OperationMessageKind.$unknown:
      return r'$unknown';
  }
}

Enum$OperationMessageKind fromJson$Enum$OperationMessageKind(String value) {
  switch (value) {
    case r'INFO':
      return Enum$OperationMessageKind.INFO;
    case r'WARNING':
      return Enum$OperationMessageKind.WARNING;
    case r'ERROR':
      return Enum$OperationMessageKind.ERROR;
    case r'PERMISSION':
      return Enum$OperationMessageKind.PERMISSION;
    case r'VALIDATION':
      return Enum$OperationMessageKind.VALIDATION;
    default:
      return Enum$OperationMessageKind.$unknown;
  }
}

enum Enum$OrderDirection {
  asc,
  desc,
  $unknown;

  factory Enum$OrderDirection.fromJson(String value) =>
      fromJson$Enum$OrderDirection(value);

  String toJson() => toJson$Enum$OrderDirection(this);
}

String toJson$Enum$OrderDirection(Enum$OrderDirection e) {
  switch (e) {
    case Enum$OrderDirection.asc:
      return r'asc';
    case Enum$OrderDirection.desc:
      return r'desc';
    case Enum$OrderDirection.$unknown:
      return r'$unknown';
  }
}

Enum$OrderDirection fromJson$Enum$OrderDirection(String value) {
  switch (value) {
    case r'asc':
      return Enum$OrderDirection.asc;
    case r'desc':
      return Enum$OrderDirection.desc;
    default:
      return Enum$OrderDirection.$unknown;
  }
}

enum Enum$__TypeKind {
  SCALAR,
  OBJECT,
  INTERFACE,
  UNION,
  ENUM,
  INPUT_OBJECT,
  LIST,
  NON_NULL,
  $unknown;

  factory Enum$__TypeKind.fromJson(String value) =>
      fromJson$Enum$__TypeKind(value);

  String toJson() => toJson$Enum$__TypeKind(this);
}

String toJson$Enum$__TypeKind(Enum$__TypeKind e) {
  switch (e) {
    case Enum$__TypeKind.SCALAR:
      return r'SCALAR';
    case Enum$__TypeKind.OBJECT:
      return r'OBJECT';
    case Enum$__TypeKind.INTERFACE:
      return r'INTERFACE';
    case Enum$__TypeKind.UNION:
      return r'UNION';
    case Enum$__TypeKind.ENUM:
      return r'ENUM';
    case Enum$__TypeKind.INPUT_OBJECT:
      return r'INPUT_OBJECT';
    case Enum$__TypeKind.LIST:
      return r'LIST';
    case Enum$__TypeKind.NON_NULL:
      return r'NON_NULL';
    case Enum$__TypeKind.$unknown:
      return r'$unknown';
  }
}

Enum$__TypeKind fromJson$Enum$__TypeKind(String value) {
  switch (value) {
    case r'SCALAR':
      return Enum$__TypeKind.SCALAR;
    case r'OBJECT':
      return Enum$__TypeKind.OBJECT;
    case r'INTERFACE':
      return Enum$__TypeKind.INTERFACE;
    case r'UNION':
      return Enum$__TypeKind.UNION;
    case r'ENUM':
      return Enum$__TypeKind.ENUM;
    case r'INPUT_OBJECT':
      return Enum$__TypeKind.INPUT_OBJECT;
    case r'LIST':
      return Enum$__TypeKind.LIST;
    case r'NON_NULL':
      return Enum$__TypeKind.NON_NULL;
    default:
      return Enum$__TypeKind.$unknown;
  }
}

enum Enum$__DirectiveLocation {
  QUERY,
  MUTATION,
  SUBSCRIPTION,
  FIELD,
  FRAGMENT_DEFINITION,
  FRAGMENT_SPREAD,
  INLINE_FRAGMENT,
  VARIABLE_DEFINITION,
  SCHEMA,
  SCALAR,
  OBJECT,
  FIELD_DEFINITION,
  ARGUMENT_DEFINITION,
  INTERFACE,
  UNION,
  ENUM,
  ENUM_VALUE,
  INPUT_OBJECT,
  INPUT_FIELD_DEFINITION,
  $unknown;

  factory Enum$__DirectiveLocation.fromJson(String value) =>
      fromJson$Enum$__DirectiveLocation(value);

  String toJson() => toJson$Enum$__DirectiveLocation(this);
}

String toJson$Enum$__DirectiveLocation(Enum$__DirectiveLocation e) {
  switch (e) {
    case Enum$__DirectiveLocation.QUERY:
      return r'QUERY';
    case Enum$__DirectiveLocation.MUTATION:
      return r'MUTATION';
    case Enum$__DirectiveLocation.SUBSCRIPTION:
      return r'SUBSCRIPTION';
    case Enum$__DirectiveLocation.FIELD:
      return r'FIELD';
    case Enum$__DirectiveLocation.FRAGMENT_DEFINITION:
      return r'FRAGMENT_DEFINITION';
    case Enum$__DirectiveLocation.FRAGMENT_SPREAD:
      return r'FRAGMENT_SPREAD';
    case Enum$__DirectiveLocation.INLINE_FRAGMENT:
      return r'INLINE_FRAGMENT';
    case Enum$__DirectiveLocation.VARIABLE_DEFINITION:
      return r'VARIABLE_DEFINITION';
    case Enum$__DirectiveLocation.SCHEMA:
      return r'SCHEMA';
    case Enum$__DirectiveLocation.SCALAR:
      return r'SCALAR';
    case Enum$__DirectiveLocation.OBJECT:
      return r'OBJECT';
    case Enum$__DirectiveLocation.FIELD_DEFINITION:
      return r'FIELD_DEFINITION';
    case Enum$__DirectiveLocation.ARGUMENT_DEFINITION:
      return r'ARGUMENT_DEFINITION';
    case Enum$__DirectiveLocation.INTERFACE:
      return r'INTERFACE';
    case Enum$__DirectiveLocation.UNION:
      return r'UNION';
    case Enum$__DirectiveLocation.ENUM:
      return r'ENUM';
    case Enum$__DirectiveLocation.ENUM_VALUE:
      return r'ENUM_VALUE';
    case Enum$__DirectiveLocation.INPUT_OBJECT:
      return r'INPUT_OBJECT';
    case Enum$__DirectiveLocation.INPUT_FIELD_DEFINITION:
      return r'INPUT_FIELD_DEFINITION';
    case Enum$__DirectiveLocation.$unknown:
      return r'$unknown';
  }
}

Enum$__DirectiveLocation fromJson$Enum$__DirectiveLocation(String value) {
  switch (value) {
    case r'QUERY':
      return Enum$__DirectiveLocation.QUERY;
    case r'MUTATION':
      return Enum$__DirectiveLocation.MUTATION;
    case r'SUBSCRIPTION':
      return Enum$__DirectiveLocation.SUBSCRIPTION;
    case r'FIELD':
      return Enum$__DirectiveLocation.FIELD;
    case r'FRAGMENT_DEFINITION':
      return Enum$__DirectiveLocation.FRAGMENT_DEFINITION;
    case r'FRAGMENT_SPREAD':
      return Enum$__DirectiveLocation.FRAGMENT_SPREAD;
    case r'INLINE_FRAGMENT':
      return Enum$__DirectiveLocation.INLINE_FRAGMENT;
    case r'VARIABLE_DEFINITION':
      return Enum$__DirectiveLocation.VARIABLE_DEFINITION;
    case r'SCHEMA':
      return Enum$__DirectiveLocation.SCHEMA;
    case r'SCALAR':
      return Enum$__DirectiveLocation.SCALAR;
    case r'OBJECT':
      return Enum$__DirectiveLocation.OBJECT;
    case r'FIELD_DEFINITION':
      return Enum$__DirectiveLocation.FIELD_DEFINITION;
    case r'ARGUMENT_DEFINITION':
      return Enum$__DirectiveLocation.ARGUMENT_DEFINITION;
    case r'INTERFACE':
      return Enum$__DirectiveLocation.INTERFACE;
    case r'UNION':
      return Enum$__DirectiveLocation.UNION;
    case r'ENUM':
      return Enum$__DirectiveLocation.ENUM;
    case r'ENUM_VALUE':
      return Enum$__DirectiveLocation.ENUM_VALUE;
    case r'INPUT_OBJECT':
      return Enum$__DirectiveLocation.INPUT_OBJECT;
    case r'INPUT_FIELD_DEFINITION':
      return Enum$__DirectiveLocation.INPUT_FIELD_DEFINITION;
    default:
      return Enum$__DirectiveLocation.$unknown;
  }
}

const possibleTypesMap = <String, Set<String>>{
  'CreateShareLinkPayload': {
    'CreateShareLinkResponse',
    'OperationInfo',
  },
  'GetShareLinkPayload': {
    'GetShareLinkResponse',
    'OperationInfo',
  },
  'SubmitListeningEventsPayload': {
    'SubmitListeningEventsResponse',
    'OperationInfo',
  },
  'TriggerMetadataFetchPayload': {
    'TriggerMetadataFetchResponse',
    'OperationInfo',
  },
};
