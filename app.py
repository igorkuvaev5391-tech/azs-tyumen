"""Веб-приложение «Заправки Тюмени».

По каждой таблице базы azs: список, добавление, изменение, удаление.
Внешний ключ выбирается из списка по названию.
Если база отвергает запись, приложение показывает ошибку и ничего не сохраняет.

Запуск: .venv\\Scripts\\python -m flask --app app run
"""
from datetime import date, datetime, time
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row
from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.security import generate_password_hash

import config

app = Flask(__name__)
app.secret_key = 'azs-tyumen-demo'  # нужен Flask для всплывающих сообщений


# ---------- Описание таблиц ----------
# Каждая таблица описана словарём: заголовок, порядок строк и столбцы.
# Вид столбца (kind) определяет поле формы:
#   text, number, date, time, datetime, bool — обычные поля;
#   choice — выбор из списка слов (options);
#   ref — внешний ключ, выбор строки из таблицы ref;
#   password — пароль, в базу пишется его хеш;
#   readonly — только показывается в списке, в форме его нет.
# sqltype — к какому типу PostgreSQL приводится введённая строка.

def col(name, label, kind='text', sqltype='text', required=False, **extra):
    return dict(name=name, label=label, kind=kind, sqltype=sqltype, required=required, **extra)


TABLES = {
    'networks': dict(
        title='Сети АЗС', one='сеть', order='name',
        columns=[
            col('name', 'Наименование', required=True),
            col('hotline', 'Телефон горячей линии', example='+7 800 100-00-01'),
            col('website', 'Сайт', example='sever-azs.ru'),
        ]),
    'districts': dict(
        title='Районы', one='район', order='name',
        columns=[col('name', 'Наименование', required=True)]),
    'stations': dict(
        title='АЗС', one='АЗС', order='network_id, number',
        columns=[
            col('network_id', 'Сеть', 'ref', 'integer', True, ref='networks'),
            col('number', 'Номер АЗС', required=True),
            col('district_id', 'Район', 'ref', 'integer', True, ref='districts'),
            col('street', 'Улица', required=True, example='ул. Республики'),
            col('house', 'Дом', required=True),
            col('latitude', 'Широта', 'number', 'numeric', True, step='0.000001'),
            col('longitude', 'Долгота', 'number', 'numeric', True, step='0.000001'),
            col('is_24h', 'Круглосуточно', 'bool', 'boolean'),
            col('opens_at', 'Открытие', 'time', 'time', hint='пусто, если круглосуточно'),
            col('closes_at', 'Закрытие', 'time', 'time', hint='пусто, если круглосуточно'),
            col('phone', 'Телефон', example='+7 345 200-00-12'),
            col('status', 'Статус', 'choice', required=True, options=['работает', 'закрыта']),
        ]),
    'fuel_types': dict(
        title='Виды топлива', one='вид топлива', order='id',
        columns=[
            col('name', 'Наименование', required=True),
            col('fuel_group', 'Группа', 'choice', required=True,
                options=['бензин', 'дизельное топливо', 'газ']),
            col('octane', 'Октановое число', 'number', 'smallint', hint='только для бензина'),
        ]),
    'roles': dict(
        title='Роли', one='роль', order='id',
        columns=[
            col('name', 'Наименование', required=True),
            col('mark_weight', 'Вес отметки', 'number', 'smallint', True),
        ]),
    'users': dict(
        title='Пользователи', one='пользователь', order='name',
        columns=[
            col('email', 'E-mail', required=True),
            col('name', 'Имя', required=True),
            col('password_hash', 'Пароль', 'password',
                hint='при изменении оставь пустым, чтобы не менять'),
            col('registered_on', 'Дата регистрации', 'date', 'date', True),
            col('is_blocked', 'Заблокирован', 'bool', 'boolean'),
            col('role_id', 'Роль', 'ref', 'integer', True, ref='roles'),
            col('network_id', 'Сеть (только оператор и интеграция)', 'ref', 'integer', ref='networks'),
        ]),
    'marks': dict(
        title='Отметки о наличии', one='отметка', order='marked_at DESC',
        columns=[
            col('station_id', 'АЗС', 'ref', 'integer', True, ref='stations'),
            col('fuel_type_id', 'Вид топлива', 'ref', 'integer', True, ref='fuel_types'),
            col('user_id', 'Автор', 'ref', 'integer', True, ref='users'),
            col('availability', 'Наличие', 'choice', required=True, options=['есть', 'нет']),
            col('price', 'Цена, ₽/л', 'number', 'numeric', step='0.01', hint='только если топливо есть'),
            col('marked_at', 'Момент отметки', 'datetime', 'timestamp', True),
            col('check_status', 'Статус проверки', 'choice', required=True,
                options=['новая', 'подтверждена', 'отклонена']),
            col('checked_by', 'Проверил (модератор)', 'ref', 'integer', ref='users'),
            col('checked_at', 'Время проверки', 'readonly'),
        ]),
    'subscriptions': dict(
        title='Подписки', one='подписка', order='id',
        columns=[
            col('user_id', 'Пользователь', 'ref', 'integer', True, ref='users'),
            col('station_id', 'АЗС', 'ref', 'integer', True, ref='stations'),
            col('fuel_type_id', 'Вид топлива', 'ref', 'integer', True, ref='fuel_types'),
            col('created_on', 'Дата создания', 'date', 'date', True),
            col('is_active', 'Активна', 'bool', 'boolean'),
        ]),
}

# Как показывать строку таблицы, на которую ссылаются: откуда брать и какое выражение.
# r — сама строка справочника.
LABELS = {
    'networks': ('networks r', 'r.name'),
    'districts': ('districts r', 'r.name'),
    'stations': ('stations r JOIN networks n ON n.id = r.network_id',
                 "n.name || ' № ' || r.number || ', ' || r.street"),
    'fuel_types': ('fuel_types r', 'r.name'),
    'roles': ('roles r', 'r.name'),
    'users': ('users r', "r.name || ' (' || r.email || ')'"),
}

# Понятные сообщения для именованных ограничений базы.
CONSTRAINT_TEXT = {
    'station_number': 'В этой сети уже есть АЗС с таким номером.',
    'station_status': 'Статус АЗС — «работает» или «закрыта».',
    'station_hours': 'У круглосуточной АЗС часы не заполняются. Иначе нужны оба часа, и закрытие позже открытия.',
    'fuel_group_list': 'Группа топлива — бензин, дизельное топливо или газ.',
    'octane_for_petrol': 'Октановое число указывается у бензина и только у него.',
    'weight_range': 'Вес отметки — от 1 до 10.',
    'availability_list': 'Наличие — «есть» или «нет».',
    'price_if_available': 'Цена указывается, только если топливо есть.',
    'check_status_list': 'Статус проверки — новая, подтверждена или отклонена.',
    'checked_when_reviewed': 'Время проверки есть у проверенной отметки и отсутствует у новой.',
    'checker_needs_time': 'Проверяющий указывается только у проверенной отметки.',
    'mark_once': 'Такая отметка уже есть: тот же автор, АЗС, топливо и время.',
    'one_active_subscription': 'У пользователя уже есть активная подписка на эту АЗС и это топливо.',
    'd_title_check': 'Название не может быть пустым.',
    'd_phone_check': 'Телефон пишется в формате +7 XXX XXX-XX-XX.',
    'd_email_check': 'E-mail указан неверно.',
    'd_price_check': 'Цена должна быть больше нуля.',
    'd_latitude_check': 'Широта — от −90 до 90.',
    'd_longitude_check': 'Долгота — от −180 до 180.',
    'd_octane_check': 'Октановое число — от 80 до 100.',
}


# ---------- Работа с базой ----------

def connect():
    return psycopg.connect(config.DATABASE_URL, row_factory=dict_row)


def fetch_all(sql, params=()):
    with connect() as conn:
        return conn.execute(sql, params).fetchall()


def fetch_one(sql, params=()):
    with connect() as conn:
        return conn.execute(sql, params).fetchone()


def run(sql, params=()):
    # Блок with фиксирует изменения при успехе и отменяет их при ошибке.
    with connect() as conn:
        conn.execute(sql, params)


def error_text(err):
    """Текст ошибки базы для человека."""
    diag = err.diag
    name = diag.constraint_name or ''
    if name in CONSTRAINT_TEXT:
        return CONSTRAINT_TEXT[name]
    if name.endswith('_fkey') and diag.table_name:
        title = TABLES.get(diag.table_name, {}).get('title', diag.table_name)
        return f'Запись связана с другой таблицей ({title}): на неё ссылаются, или выбранной строки нет.'
    if name.endswith('_key'):
        return 'Такое значение уже есть в таблице, а оно должно быть уникальным.'
    text = diag.message_primary or str(err)
    if diag.sqlstate == '23502':
        return 'Не заполнено обязательное поле.'
    if diag.sqlstate and diag.sqlstate.startswith('22'):
        return 'Значение введено в неверном формате: ' + text
    return text


def table_or_404(name):
    if name not in TABLES:
        abort(404)
    return TABLES[name]


def form_columns(t):
    return [c for c in t['columns'] if c['kind'] != 'readonly']


def ref_options(ref):
    source, expr = LABELS[ref]
    return fetch_all(f'SELECT r.id, {expr} AS label FROM {source} ORDER BY label')


def as_input(value, kind):
    """Значение из базы → строка для поля формы."""
    if value is None:
        return ''
    if isinstance(value, bool):
        return 'on' if value else ''
    if kind == 'datetime' and isinstance(value, datetime):
        return value.strftime('%Y-%m-%dT%H:%M')
    if kind == 'time' and isinstance(value, time):
        return value.strftime('%H:%M')
    if isinstance(value, (date, Decimal, int)):
        return str(value)
    return value


@app.template_filter('show')
def show(value):
    """Значение из базы → текст в таблице списка."""
    if value is None:
        return '—'
    if value is True:
        return 'да'
    if value is False:
        return 'нет'
    if isinstance(value, datetime):
        return value.strftime('%d.%m.%Y %H:%M')
    if isinstance(value, date):
        return value.strftime('%d.%m.%Y')
    if isinstance(value, time):
        return value.strftime('%H:%M')
    return value


def read_form(t, is_new):
    """Поля формы → значения для SQL. Пустое поле — это NULL."""
    values = {}
    for c in form_columns(t):
        if c['kind'] == 'bool':
            values[c['name']] = 'true' if request.form.get(c['name']) else 'false'
            continue
        raw = request.form.get(c['name'], '').strip()
        if c['kind'] == 'password':
            if raw:
                values[c['name']] = generate_password_hash(raw, method='pbkdf2:sha256')
            elif is_new:
                values[c['name']] = None  # база ответит: пароль обязателен
            continue  # при изменении пустой пароль не трогаем
        values[c['name']] = raw or None
    return values


def sqltype_of(t, name):
    return next(c['sqltype'] for c in t['columns'] if c['name'] == name)


# ---------- Страницы ----------

@app.context_processor
def inject_tables():
    # Список таблиц нужен меню слева на каждой странице.
    return {'tables': TABLES}


@app.route('/')
def index():
    counts = {}
    for name in TABLES:
        counts[name] = fetch_one(f'SELECT count(*) AS n FROM {name}')['n']
    stations = fetch_all(
        "SELECT s.id, n.name || ' № ' || s.number AS label, s.street, s.status "
        'FROM stations s JOIN networks n ON n.id = s.network_id ORDER BY n.name, s.number')
    return render_template('index.html', counts=counts, stations=stations)


@app.route('/<table>/')
def list_rows(table):
    t = table_or_404(table)
    parts = [f'{table}.*']
    for c in t['columns']:
        if c['kind'] == 'ref':
            source, expr = LABELS[c['ref']]
            parts.append(f"(SELECT {expr} FROM {source} WHERE r.id = {table}.{c['name']}) AS {c['name']}__label")
    rows = fetch_all(f"SELECT {', '.join(parts)} FROM {table} ORDER BY {t['order']}")
    shown = [c for c in t['columns'] if c['kind'] != 'password']
    return render_template('list.html', table=table, t=t, rows=rows, columns=shown)


@app.route('/<table>/new', methods=['GET', 'POST'])
def create_row(table):
    t = table_or_404(table)
    if request.method == 'POST':
        values = read_form(t, is_new=True)
        names = list(values)
        casts = ', '.join(f'CAST(%s AS {sqltype_of(t, n)})' for n in names)
        sql = f"INSERT INTO {table} ({', '.join(names)}) VALUES ({casts})"
        try:
            run(sql, [values[n] for n in names])
        except psycopg.Error as err:
            return show_form(table, t, request.form, error_text(err), row_id=None)
        flash(f"Запись добавлена: {t['one']}.")
        return redirect(url_for('list_rows', table=table))
    return show_form(table, t, defaults(t), None, row_id=None)


@app.route('/<table>/<int:row_id>/edit', methods=['GET', 'POST'])
def edit_row(table, row_id):
    t = table_or_404(table)
    if request.method == 'POST':
        values = read_form(t, is_new=False)
        names = list(values)
        sets = ', '.join(f'{n} = CAST(%s AS {sqltype_of(t, n)})' for n in names)
        try:
            run(f'UPDATE {table} SET {sets} WHERE id = %s', [values[n] for n in names] + [row_id])
        except psycopg.Error as err:
            return show_form(table, t, request.form, error_text(err), row_id=row_id)
        flash(f"Изменения сохранены: {t['one']} № {row_id}.")
        return redirect(url_for('list_rows', table=table))
    row = fetch_one(f'SELECT * FROM {table} WHERE id = %s', [row_id])
    if row is None:
        abort(404)
    current = {c['name']: as_input(row[c['name']], c['kind'])
               for c in form_columns(t) if c['kind'] != 'password'}
    return show_form(table, t, current, None, row_id=row_id)


@app.route('/<table>/<int:row_id>/delete', methods=['POST'])
def delete_row(table, row_id):
    t = table_or_404(table)
    try:
        run(f'DELETE FROM {table} WHERE id = %s', [row_id])
    except psycopg.Error as err:
        flash(f"Не удалось удалить {t['one']} № {row_id}. {error_text(err)}", 'error')
        return redirect(url_for('list_rows', table=table))
    flash(f"Удалено: {t['one']} № {row_id}.")
    return redirect(url_for('list_rows', table=table))


def defaults(t):
    """Значения новой записи по умолчанию."""
    now = datetime.now()
    values = {}
    for c in form_columns(t):
        if c['kind'] == 'date':
            values[c['name']] = now.strftime('%Y-%m-%d')
        elif c['kind'] == 'datetime':
            values[c['name']] = now.strftime('%Y-%m-%dT%H:%M')
        elif c['kind'] == 'choice':
            values[c['name']] = c['options'][0]
        elif c['name'] == 'is_active':
            values[c['name']] = 'on'
    return values


def show_form(table, t, values, error, row_id):
    options = {c['name']: ref_options(c['ref']) for c in form_columns(t) if c['kind'] == 'ref'}
    return render_template('form.html', table=table, t=t, columns=form_columns(t), values=values,
                           options=options, error=error, row_id=row_id), (400 if error else 200)


@app.route('/stations/<int:station_id>/card')
def station_card(station_id):
    head = fetch_one(
        'SELECT s.*, n.name AS network, n.hotline, d.name AS district '
        'FROM stations s JOIN networks n ON n.id = s.network_id '
        'JOIN districts d ON d.id = s.district_id WHERE s.id = %s', [station_id])
    if head is None:
        abort(404)
    fuels = fetch_all(
        'SELECT f.name, fs.status, fs.price, fs.updated_at, fs.source '
        'FROM fuel_status fs JOIN fuel_types f ON f.id = fs.fuel_type_id '
        'WHERE fs.station_id = %s ORDER BY f.id', [station_id])
    return render_template('card.html', s=head, fuels=fuels, now=datetime.now())
