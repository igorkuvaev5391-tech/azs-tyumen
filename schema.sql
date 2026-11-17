-- База данных «Заправки Тюмени» (АЗС).
-- Имена базы, таблиц и столбцов английские. Текст в ячейках русский.
--
-- Запуск файла целиком (Windows, PowerShell, из папки проекта):
--   & "C:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d postgres -f schema.sql
--
-- DBeaver: часть 1 выполнить на базе postgres, затем открыть базу azs и выполнить остальное.
-- Строки \connect в DBeaver пропустить: это команды psql, не SQL.
--
-- Повторный запуск стирает базу azs и собирает её заново.
-- Ошибочные команды в части 8 нужны для проверки: база должна от них отказаться.

\connect postgres
SET client_encoding TO 'UTF8';

-- ========== ЧАСТЬ 1. База ==========
-- Локаль берётся у сервера: на русской Windows это Russian_Russia, сортировка русских слов верная.

DROP DATABASE IF EXISTS azs;
CREATE DATABASE azs
    TEMPLATE template0
    ENCODING 'UTF8';

\connect azs
SET client_encoding TO 'UTF8';

-- ========== ЧАСТЬ 2. Домены ==========
-- Домен — тип с правилом. Правило пишется один раз и действует во всех столбцах этого типа.

-- Название: не пустое и не из одних пробелов.
CREATE DOMAIN d_title AS varchar(100)
    CHECK (btrim(VALUE) <> '');

-- Телефон в формате +7 XXX XXX-XX-XX.
CREATE DOMAIN d_phone AS varchar(16)
    CHECK (VALUE ~ '^\+7 \d{3} \d{3}-\d{2}-\d{2}$');

-- E-mail: что-то@что-то.зона, без пробелов.
CREATE DOMAIN d_email AS varchar(254)
    CHECK (VALUE ~* '^[^@\s]+@[^@\s]+\.[a-zа-я]{2,}$');

-- Цена за литр: больше нуля, две цифры после запятой.
CREATE DOMAIN d_price AS numeric(7, 2)
    CHECK (VALUE > 0);

-- Координаты в градусах.
CREATE DOMAIN d_latitude AS numeric(9, 6)
    CHECK (VALUE BETWEEN -90 AND 90);

CREATE DOMAIN d_longitude AS numeric(9, 6)
    CHECK (VALUE BETWEEN -180 AND 180);

-- Октановое число бензина.
CREATE DOMAIN d_octane AS smallint
    CHECK (VALUE BETWEEN 80 AND 100);

-- ========== ЧАСТЬ 3. Таблицы ==========
-- Сначала справочники, на которые ссылаются. Потом таблицы, которые ссылаются.
-- Удалить строку, на которую есть ссылка, нельзя: ON DELETE RESTRICT.

-- Сеть АЗС. Независимые АЗС относятся к сети «Независимые».
CREATE TABLE networks (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name d_title NOT NULL UNIQUE,
    hotline d_phone,
    website varchar(200)
);

-- Район города. Список закрытый: четыре района Тюмени.
CREATE TABLE districts (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name d_title NOT NULL UNIQUE
);

-- АЗС. Номер повторяется в разных сетях, поэтому уникальна пара «сеть + номер».
CREATE TABLE stations (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    network_id integer NOT NULL REFERENCES networks (id) ON DELETE RESTRICT,
    number varchar(20) NOT NULL,
    district_id integer NOT NULL REFERENCES districts (id) ON DELETE RESTRICT,
    street varchar(100) NOT NULL,
    house varchar(10) NOT NULL,
    latitude d_latitude NOT NULL,
    longitude d_longitude NOT NULL,
    is_24h boolean NOT NULL DEFAULT false,
    opens_at time,
    closes_at time,
    phone d_phone,
    status varchar(10) NOT NULL DEFAULT 'работает',
    CONSTRAINT station_number UNIQUE (network_id, number),
    CONSTRAINT station_status CHECK (status IN ('работает', 'закрыта')),
    -- Круглосуточная: часов нет. Иначе оба часа есть, и закрытие позже открытия.
    CONSTRAINT station_hours CHECK (
        (is_24h AND opens_at IS NULL AND closes_at IS NULL)
        OR (NOT is_24h AND opens_at IS NOT NULL AND closes_at IS NOT NULL AND closes_at > opens_at)
    )
);

-- Вид топлива. Октановое число есть только у бензина.
CREATE TABLE fuel_types (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(30) NOT NULL UNIQUE,
    fuel_group varchar(20) NOT NULL,
    octane d_octane,
    CONSTRAINT fuel_group_list CHECK (fuel_group IN ('бензин', 'дизельное топливо', 'газ')),
    CONSTRAINT octane_for_petrol CHECK ((fuel_group = 'бензин') = (octane IS NOT NULL))
);

-- Роль пользователя и вес его отметки в итоговом статусе.
CREATE TABLE roles (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(20) NOT NULL UNIQUE,
    mark_weight smallint NOT NULL,
    CONSTRAINT weight_range CHECK (mark_weight BETWEEN 1 AND 10)
);

-- Пользователь. Сеть заполнена только у оператора и интеграции (проверяет триггер).
CREATE TABLE users (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email d_email NOT NULL UNIQUE,
    name d_title NOT NULL,
    password_hash varchar(255) NOT NULL,
    registered_on date NOT NULL DEFAULT current_date,
    is_blocked boolean NOT NULL DEFAULT false,
    role_id integer NOT NULL REFERENCES roles (id) ON DELETE RESTRICT,
    network_id integer REFERENCES networks (id) ON DELETE RESTRICT
);

-- Отметка о наличии топлива. Из отметок считается статус в карточке АЗС.
CREATE TABLE marks (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    station_id integer NOT NULL REFERENCES stations (id) ON DELETE RESTRICT,
    fuel_type_id integer NOT NULL REFERENCES fuel_types (id) ON DELETE RESTRICT,
    user_id integer NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    availability varchar(5) NOT NULL,
    price d_price,
    marked_at timestamp NOT NULL DEFAULT localtimestamp(0),
    check_status varchar(15) NOT NULL DEFAULT 'новая',
    checked_by integer REFERENCES users (id) ON DELETE RESTRICT,
    checked_at timestamp,
    CONSTRAINT mark_once UNIQUE (station_id, fuel_type_id, user_id, marked_at),
    CONSTRAINT availability_list CHECK (availability IN ('есть', 'нет')),
    -- Цена бывает только у топлива, которое есть.
    CONSTRAINT price_if_available CHECK (availability = 'есть' OR price IS NULL),
    CONSTRAINT check_status_list CHECK (check_status IN ('новая', 'подтверждена', 'отклонена')),
    -- Новая отметка ещё не проверена: нет ни времени, ни проверяющего.
    CONSTRAINT checked_when_reviewed CHECK ((check_status = 'новая') = (checked_at IS NULL)),
    CONSTRAINT checker_needs_time CHECK (checked_by IS NULL OR checked_at IS NOT NULL)
);

-- Подписка «сообщить, когда на АЗС появится топливо».
CREATE TABLE subscriptions (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id integer NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    station_id integer NOT NULL REFERENCES stations (id) ON DELETE RESTRICT,
    fuel_type_id integer NOT NULL REFERENCES fuel_types (id) ON DELETE RESTRICT,
    created_on date NOT NULL DEFAULT current_date,
    is_active boolean NOT NULL DEFAULT true
);

-- Активная подписка на пару «АЗС + топливо» у пользователя одна. Неактивных может быть сколько угодно.
CREATE UNIQUE INDEX one_active_subscription
    ON subscriptions (user_id, station_id, fuel_type_id)
    WHERE is_active;

-- ========== ЧАСТЬ 4. Хранимые процедуры и триггеры ==========
-- CHECK видит только свою строку. Правила, которым нужна соседняя таблица, держат триггеры.

-- 1. Сеть есть у оператора и интеграции и только у них.
CREATE OR REPLACE FUNCTION check_user_network() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    role_name varchar;
BEGIN
    SELECT name INTO role_name FROM roles WHERE id = NEW.role_id;

    IF role_name IN ('оператор', 'интеграция')
       AND NEW.network_id IS NULL THEN
        RAISE EXCEPTION
            'У роли «%» должна быть указана сеть АЗС',
            role_name;
    END IF;

    IF role_name NOT IN ('оператор', 'интеграция')
       AND NEW.network_id IS NOT NULL THEN
        RAISE EXCEPTION
            'Сеть АЗС указывается только оператору и интеграции, а не роли «%»',
            role_name;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER user_network
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION check_user_network();

-- 2. Новая отметка: кто, где и когда может её оставить.
CREATE OR REPLACE FUNCTION check_new_mark() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    author record;
    station record;
BEGIN
    SELECT users.is_blocked, users.network_id, roles.name AS role_name
    INTO author
    FROM users JOIN roles ON roles.id = users.role_id
    WHERE users.id = NEW.user_id;

    SELECT network_id, status INTO station FROM stations WHERE id = NEW.station_id;

    IF author.is_blocked THEN
        RAISE EXCEPTION 'Пользователь заблокирован и не может оставлять отметки';
    END IF;

    IF author.role_name = 'модератор' THEN
        RAISE EXCEPTION 'Модератор проверяет отметки, а не оставляет их';
    END IF;

    IF station.status = 'закрыта' THEN
        RAISE EXCEPTION 'АЗС закрыта: отметки по ней не принимаются';
    END IF;

    IF NEW.marked_at > localtimestamp + interval '1 minute' THEN
        RAISE EXCEPTION 'Время отметки % ещё не наступило', NEW.marked_at;
    END IF;

    IF author.role_name IN ('оператор', 'интеграция') THEN
        -- Оператор отмечает любую АЗС своей сети, чужую — нет.
        IF station.network_id <> author.network_id THEN
            RAISE EXCEPTION 'АЗС относится к другой сети: оператор отмечает только АЗС своей сети';
        END IF;
        -- Отметка оператора и интеграции подтверждается сразу.
        NEW.check_status := 'подтверждена';
        NEW.checked_at := NEW.marked_at;
        NEW.checked_by := NULL;
    ELSE
        -- Водитель отмечает одну пару «АЗС + топливо» не чаще раза в 15 минут.
        IF EXISTS (
            SELECT 1 FROM marks
            WHERE user_id = NEW.user_id
              AND station_id = NEW.station_id
              AND fuel_type_id = NEW.fuel_type_id
              AND marked_at > NEW.marked_at - interval '15 minutes'
              AND marked_at < NEW.marked_at + interval '15 minutes'
        ) THEN
            RAISE EXCEPTION 'По этой АЗС и этому топливу отметка уже была меньше 15 минут назад';
        END IF;
        NEW.check_status := 'новая';
        NEW.checked_at := NULL;
        NEW.checked_by := NULL;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER new_mark
BEFORE INSERT ON marks
FOR EACH ROW
EXECUTE FUNCTION check_new_mark();

-- 3. Проверка отметки: только модератор и только «новая» → «подтверждена» / «отклонена».
CREATE OR REPLACE FUNCTION check_mark_review() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    checker_role varchar;
BEGIN
    IF NEW.check_status = OLD.check_status THEN
        RETURN NEW;
    END IF;

    IF OLD.check_status <> 'новая' THEN
        RAISE EXCEPTION 'Отметка уже проверена (%), статус больше не меняется', OLD.check_status;
    END IF;

    SELECT roles.name INTO checker_role
    FROM users JOIN roles ON roles.id = users.role_id
    WHERE users.id = NEW.checked_by;

    IF checker_role IS DISTINCT FROM 'модератор' THEN
        RAISE EXCEPTION 'Проверять отметки может только модератор';
    END IF;

    NEW.checked_at := coalesce(NEW.checked_at, localtimestamp(0));
    RETURN NEW;
END;
$$;

CREATE TRIGGER mark_review
BEFORE UPDATE ON marks
FOR EACH ROW
EXECUTE FUNCTION check_mark_review();

-- 4. Подписку оформляет только незаблокированный пользователь.
CREATE OR REPLACE FUNCTION check_subscription() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT is_blocked FROM users WHERE id = NEW.user_id) THEN
        RAISE EXCEPTION 'Пользователь заблокирован и не может оформлять подписки';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER new_subscription
BEFORE INSERT ON subscriptions
FOR EACH ROW
EXECUTE FUNCTION check_subscription();

-- ========== ЧАСТЬ 5. Представление «наличие топлива» ==========
-- Отдельной таблицы наличия нет: статус считается из отметок за 2 часа, кроме отклонённых.
-- S = сумма(вес · s) / сумма(весов), s = 1 для «есть», 0 для «нет». S >= 0,5 — «есть».

CREATE VIEW fuel_status AS
WITH recent AS (
    SELECT marks.*, roles.mark_weight, roles.name AS source,
           row_number() OVER (
               PARTITION BY marks.station_id, marks.fuel_type_id
               ORDER BY marks.marked_at DESC
           ) AS rn
    FROM marks
    JOIN users ON users.id = marks.user_id
    JOIN roles ON roles.id = users.role_id
    WHERE marks.check_status <> 'отклонена'
      AND marks.marked_at >= localtimestamp - interval '2 hours'
),
score AS (
    SELECT station_id, fuel_type_id,
           sum(mark_weight * CASE WHEN availability = 'есть' THEN 1 ELSE 0 END)::numeric
               / sum(mark_weight) AS s
    FROM recent
    GROUP BY station_id, fuel_type_id
)
SELECT stations.id AS station_id,
       fuel_types.id AS fuel_type_id,
       CASE
           WHEN score.s IS NULL THEN 'нет данных'
           WHEN score.s >= 0.5 THEN 'есть'
           ELSE 'нет'
       END AS status,
       last.price,
       last.marked_at AS updated_at,
       last.source
FROM stations
CROSS JOIN fuel_types
LEFT JOIN score ON score.station_id = stations.id AND score.fuel_type_id = fuel_types.id
LEFT JOIN recent AS last
       ON last.station_id = stations.id AND last.fuel_type_id = fuel_types.id AND last.rn = 1
WHERE stations.status = 'работает';

-- ========== ЧАСТЬ 6. Данные ==========
-- Номер id в INSERT не пишем: его ставит база. Связи ищут строки по имени.
-- Время отметок считается от текущего момента, чтобы карточка всегда показывала свежие данные.

INSERT INTO networks (name, hotline, website) VALUES
    ('Север', '+7 800 100-00-01', 'sever-azs.ru'),
    ('Магистраль', '+7 800 200-00-02', 'magistral72.ru'),
    ('Независимые', NULL, NULL);

INSERT INTO districts (name) VALUES
    ('Центральный'),
    ('Ленинский'),
    ('Калининский'),
    ('Восточный');

INSERT INTO stations (network_id, number, district_id, street, house, latitude, longitude,
                      is_24h, opens_at, closes_at, phone, status) VALUES
    (
        (SELECT id FROM networks WHERE name = 'Север'), '12',
        (SELECT id FROM districts WHERE name = 'Ленинский'),
        'ул. Республики', '100', 57.153000, 65.534000,
        true, NULL, NULL, '+7 345 200-00-12', 'работает'
    ),
    (
        (SELECT id FROM networks WHERE name = 'Север'), '7',
        (SELECT id FROM districts WHERE name = 'Калининский'),
        'ул. Широтная', '45', 57.121000, 65.560000,
        false, TIME '07:00', TIME '23:00', '+7 345 200-00-07', 'работает'
    ),
    (
        (SELECT id FROM networks WHERE name = 'Магистраль'), '3',
        (SELECT id FROM districts WHERE name = 'Центральный'),
        'ул. Мельникайте', '20', 57.145000, 65.560000,
        true, NULL, NULL, '+7 345 300-00-03', 'работает'
    ),
    (
        (SELECT id FROM networks WHERE name = 'Независимые'), '1',
        (SELECT id FROM districts WHERE name = 'Восточный'),
        'ул. Федюнинского', '10', 57.140000, 65.620000,
        false, TIME '08:00', TIME '20:00', NULL, 'закрыта'
    );

INSERT INTO fuel_types (name, fuel_group, octane) VALUES
    ('АИ-92', 'бензин', 92),
    ('АИ-95', 'бензин', 95),
    ('АИ-98', 'бензин', 98),
    ('ДТ', 'дизельное топливо', NULL),
    ('Газ (СУГ)', 'газ', NULL);

INSERT INTO roles (name, mark_weight) VALUES
    ('водитель', 1),
    ('оператор', 3),
    ('интеграция', 2),
    ('модератор', 1);

-- Пароли условные: md5 от учебной строки. Настоящее приложение хранит стойкий хеш (bcrypt).
INSERT INTO users (email, name, password_hash, registered_on, role_id, network_id) VALUES
    ('petrov@sever-azs.ru', 'Иван Петров', md5('demo-petrov'), DATE '2026-09-01',
        (SELECT id FROM roles WHERE name = 'оператор'),
        (SELECT id FROM networks WHERE name = 'Север')),
    ('api@magistral72.ru', 'Шлюз «Магистраль»', md5('demo-api'), DATE '2026-09-01',
        (SELECT id FROM roles WHERE name = 'интеграция'),
        (SELECT id FROM networks WHERE name = 'Магистраль')),
    ('ivanova@mail.ru', 'Анна Иванова', md5('demo-ivanova'), DATE '2026-10-02',
        (SELECT id FROM roles WHERE name = 'водитель'), NULL),
    ('kim@mail.ru', 'Мария Ким', md5('demo-kim'), DATE '2026-10-15',
        (SELECT id FROM roles WHERE name = 'водитель'), NULL),
    ('Igor.kuaveyv@bk.ru', 'Игорь Куваев', md5('demo-kuvaev'), DATE '2026-09-01',
        (SELECT id FROM roles WHERE name = 'модератор'), NULL);

-- Статус проверки не пишем: его ставит триггер new_mark.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability, price, marked_at) VALUES
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92'),
        (SELECT id FROM users WHERE email = 'petrov@sever-azs.ru'),
        'есть', 54.10, localtimestamp(0) - interval '20 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-95'),
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        'есть', 58.30, localtimestamp(0) - interval '40 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-98'),
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        'нет', NULL, localtimestamp(0) - interval '30 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-98'),
        (SELECT id FROM users WHERE email = 'kim@mail.ru'),
        'нет', NULL, localtimestamp(0) - interval '25 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'ДТ'),
        (SELECT id FROM users WHERE email = 'petrov@sever-azs.ru'),
        'есть', 69.50, localtimestamp(0) - interval '20 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '7'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92'),
        (SELECT id FROM users WHERE email = 'petrov@sever-azs.ru'),
        'нет', NULL, localtimestamp(0) - interval '10 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '3'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-95'),
        (SELECT id FROM users WHERE email = 'api@magistral72.ru'),
        'есть', 57.90, localtimestamp(0) - interval '5 minutes'
    ),
    (
        (SELECT id FROM stations WHERE number = '3'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-95'),
        (SELECT id FROM users WHERE email = 'kim@mail.ru'),
        'нет', NULL, localtimestamp(0) - interval '50 minutes'
    ),
    -- Старая отметка: больше 2 часов назад, в карточку не попадает.
    (
        (SELECT id FROM stations WHERE number = '7'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-95'),
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        'есть', 58.00, localtimestamp(0) - interval '5 hours'
    );

INSERT INTO subscriptions (user_id, station_id, fuel_type_id) VALUES
    (
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-98')
    ),
    (
        (SELECT id FROM users WHERE email = 'kim@mail.ru'),
        (SELECT id FROM stations WHERE number = '7'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92')
    );

-- Модератор подтверждает отметку Ивановой по АИ-95 и отклоняет отметку Ким на АЗС № 3.
UPDATE marks
SET check_status = 'подтверждена',
    checked_by = (SELECT id FROM users WHERE email = 'Igor.kuaveyv@bk.ru')
WHERE user_id = (SELECT id FROM users WHERE email = 'ivanova@mail.ru')
  AND fuel_type_id = (SELECT id FROM fuel_types WHERE name = 'АИ-95')
  AND station_id = (SELECT id FROM stations WHERE number = '12');

UPDATE marks
SET check_status = 'отклонена',
    checked_by = (SELECT id FROM users WHERE email = 'Igor.kuaveyv@bk.ru')
WHERE user_id = (SELECT id FROM users WHERE email = 'kim@mail.ru')
  AND station_id = (SELECT id FROM stations WHERE number = '3');

-- ========== ЧАСТЬ 7. Что лежит в базе ==========

SELECT * FROM networks ORDER BY id;
SELECT * FROM districts ORDER BY id;
SELECT id, number, street, house, is_24h, opens_at, closes_at, status FROM stations ORDER BY id;
SELECT * FROM fuel_types ORDER BY id;
SELECT * FROM roles ORDER BY id;
SELECT id, email, name, role_id, network_id, is_blocked FROM users ORDER BY id;
SELECT id, station_id, fuel_type_id, user_id, availability, price, check_status, checked_by FROM marks ORDER BY id;
SELECT * FROM subscriptions ORDER BY id;

-- Карточка АЗС № 12 сети «Север»: шапка и наличие топлива.
SELECT stations.number, networks.name AS network, districts.name AS district,
       stations.street || ', д. ' || stations.house AS address,
       CASE WHEN stations.is_24h THEN 'круглосуточно'
            ELSE to_char(stations.opens_at, 'HH24:MI') || '–' || to_char(stations.closes_at, 'HH24:MI')
       END AS hours,
       stations.phone, stations.status
FROM stations
JOIN networks ON networks.id = stations.network_id
JOIN districts ON districts.id = stations.district_id
WHERE networks.name = 'Север' AND stations.number = '12';

SELECT fuel_types.name AS fuel, fuel_status.status, fuel_status.price,
       to_char(fuel_status.updated_at, 'HH24:MI') AS updated, fuel_status.source
FROM fuel_status
JOIN fuel_types ON fuel_types.id = fuel_status.fuel_type_id
JOIN stations ON stations.id = fuel_status.station_id
JOIN networks ON networks.id = stations.network_id
WHERE networks.name = 'Север' AND stations.number = '12'
ORDER BY fuel_types.id;

-- Где сейчас есть АИ-95.
SELECT networks.name AS network, stations.number, stations.street, fuel_status.price
FROM fuel_status
JOIN stations ON stations.id = fuel_status.station_id
JOIN networks ON networks.id = stations.network_id
JOIN fuel_types ON fuel_types.id = fuel_status.fuel_type_id
WHERE fuel_types.name = 'АИ-95' AND fuel_status.status = 'есть'
ORDER BY fuel_status.price;

-- Очередь модератора: новые отметки водителей.
SELECT marks.id, users.name, stations.number, fuel_types.name AS fuel, marks.availability, marks.marked_at
FROM marks
JOIN users ON users.id = marks.user_id
JOIN stations ON stations.id = marks.station_id
JOIN fuel_types ON fuel_types.id = marks.fuel_type_id
WHERE marks.check_status = 'новая'
ORDER BY marks.marked_at;

-- ========== ЧАСТЬ 8. Отказы ==========
-- Следующие команды должны завершиться ошибкой.

-- Цена 0: домен d_price.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability, price) VALUES
    (
        (SELECT id FROM stations WHERE number = '7'),
        (SELECT id FROM fuel_types WHERE name = 'ДТ'),
        (SELECT id FROM users WHERE email = 'kim@mail.ru'),
        'есть', 0
    );

-- Телефон не по формату: домен d_phone.
INSERT INTO networks (name, hotline) VALUES ('Тест', '8-800-555');

-- Водителю нельзя указать сеть: триггер user_network.
UPDATE users
SET network_id = (SELECT id FROM networks WHERE name = 'Север')
WHERE email = 'kim@mail.ru';

-- Оператор «Севера» отмечает АЗС «Магистрали»: триггер new_mark.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability, price) VALUES
    (
        (SELECT id FROM stations WHERE number = '3'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92'),
        (SELECT id FROM users WHERE email = 'petrov@sever-azs.ru'),
        'есть', 54.00
    );

-- Иванова повторно отмечает АИ-98 на АЗС № 12 через 10 минут: правило 15 минут.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability, marked_at) VALUES
    (
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-98'),
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        'нет', localtimestamp(0) - interval '20 minutes'
    );

-- Отметка по закрытой АЗС: триггер new_mark.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability) VALUES
    (
        (SELECT id FROM stations WHERE number = '1'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92'),
        (SELECT id FROM users WHERE email = 'kim@mail.ru'),
        'нет'
    );

-- Водитель пытается проверить отметку: триггер mark_review.
UPDATE marks
SET check_status = 'подтверждена',
    checked_by = (SELECT id FROM users WHERE email = 'kim@mail.ru')
WHERE check_status = 'новая'
  AND user_id = (SELECT id FROM users WHERE email = 'ivanova@mail.ru');

-- Вторая активная подписка на ту же пару: уникальный индекс one_active_subscription.
INSERT INTO subscriptions (user_id, station_id, fuel_type_id) VALUES
    (
        (SELECT id FROM users WHERE email = 'ivanova@mail.ru'),
        (SELECT id FROM stations WHERE number = '12'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-98')
    );

-- АЗС с отметками удалить нельзя: внешний ключ. Вместо удаления ставят статус «закрыта».
DELETE FROM stations WHERE number = '12';

-- ========== ЧАСТЬ 9. Правка в одной строке ==========

-- Сеть «Север» сменила телефон горячей линии: правится одна строка networks.
UPDATE networks SET hotline = '+7 800 100-00-99' WHERE name = 'Север';

-- Петров переходит оператором в «Магистраль»: правится одна строка users.
UPDATE users
SET network_id = (SELECT id FROM networks WHERE name = 'Магистраль')
WHERE email = 'petrov@sever-azs.ru';

-- Теперь он может отметить АЗС № 3 «Магистрали». Эта команда проходит.
INSERT INTO marks (station_id, fuel_type_id, user_id, availability, price) VALUES
    (
        (SELECT id FROM stations WHERE number = '3'),
        (SELECT id FROM fuel_types WHERE name = 'АИ-92'),
        (SELECT id FROM users WHERE email = 'petrov@sever-azs.ru'),
        'есть', 54.00
    );

SELECT users.name, networks.name AS network, roles.name AS role
FROM users
JOIN roles ON roles.id = users.role_id
LEFT JOIN networks ON networks.id = users.network_id
ORDER BY users.id;
