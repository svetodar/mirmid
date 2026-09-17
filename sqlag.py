import re
import httpx
import datetime
import uuid
import json
import argparse
import glob
from openai import OpenAI
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2 import Error
from pathlib import Path
import shutil
import hashlib

# --- RICH IMPORTS FOR BEAUTIFUL CONSOLE OUTPUT ---
from rich.console import Console
from rich.console import Group
from rich.text import Text
from rich.markdown import Markdown
from rich.live import Live
from rich.panel import Panel
from rich.syntax import Syntax

# Инициализация консоли Rich
console = Console()

custom_timeout = httpx.Timeout(900.0, connect=10.0)

# LM Studio
client = OpenAI(
    base_url="http://192.168.3.98:1234/v1",
   api_key="OPENAI_API_KEY"
)
#MODEL = "qwen3.8-27b@q6_k_m"
MODEL = "qwen3.8-27b@q4_k_m"

# Настройки подключения к LLM (оставляем ваш активный DeepSeek)
#client = OpenAI(
#    api_key="sk-99fcfd9d46a24e8ca597e52a3fbf9066",
#    base_url="https://api.deepseek.com"
#)
#MODEL = "deepseek-flash"


TEMPERATURE = 0.1

# Настройки подключения к целевой базе (исправлены лишние пробелы в ключах)
TEST_DB_CONFIG = {
    "dbname": "test",
    "user": "test_owner",
    "password": "1",
    "host": "localhost",
    "port": "5432"
}

# Настройки БД для хранения контекста
TEAM_DB_CONFIG = {
    "dbname": "team",
    "user": "team_owner",
    "password": "1",
    "host": "localhost",
    "port": "5432"
}

# 1. Описание инструментов (без изменений)
tools = [
    {"type": "function", "function": {"name": "file_list", "description": "Получение списка файлов в папке. Возвращается имя, размер и хеш файла.", "parameters": {"type": "object", "properties": {"folder": {"type": "string", "description": "Папка с файлами (например, 'folder/subfolder')"}, "mask": {"type": "string", "description": "Маска файлов (например, '*.txt')"}}, "required": ["folder", "mask"]}}},
    {"type": "function", "function": {"name": "exist_file", "description": "Проверяет существование файла.", "parameters": {"type": "object", "properties": {"filename": {"type": "string", "description": "Имя файла (например, 'main/agent.md')"}}, "required": ["filename"]}}},
    {"type": "function", "function": {"name": "read_lines", "description": "Читает часть строк тестового файла. Диапазон индексов строк задается параметрами first_line и last_line так же как в Python.", "parameters": {"type": "object", "properties": {"filename": {"type": "string", "description": "Имя файла"}, "first_line": {"type": "integer", "description": "Начало диапазона"}, "last_line": {"type": "integer", "description": "Конец диапазона"}}, "required": ["filename"]}}},
    {"type": "function", "function": {"name": "read_text_file", "description": "Читает содержимое текстового файла.", "parameters": {"type": "object", "properties": {"filename": {"type": "string", "description": "Имя файла"}}, "required": ["filename"]}}},
    {"type": "function", "function": {"name": "write_text_file", "description": "Создает новый файл или перезаписывает его.", "parameters": {"type": "object", "properties": {"filename": {"type": "string", "description": "Имя файла"}, "content": {"type": "string", "description": "Текст для записи"}}, "required": ["filename", "content"]}}},
    {"type": "function", "function": {"name": "copy_file", "description": "Копирует файл.", "parameters": {"type": "object", "properties": {"source": {"type": "string", "description": "Имя копируемого файла"}, "destination": {"type": "string", "description": "Имя нового файла"}}, "required": ["source", "destination"]}}},
    {"type": "function", "function": {"name": "execute_sql_query", "description": "Выполняет SQL-запрос к базе данных PostgreSQL 15 и возвращает результат в формате JSON.", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "Текст SQL-запроса"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "get_table_def_from_db", "description": "Получает из базы данных определение таблицы и ее столбцов.", "parameters": {"type": "object", "properties": {"tablename": {"type": "string", "description": "Имя таблицы включая схему"}}, "required": ["tablename"]}}},
    {"type": "function", "function": {"name": "get_routine_def_from_db", "description": "Получает из базы данных определение процедуры или функции.", "parameters": {"type": "object", "properties": {"routinename": {"type": "string", "description": "Имя процедуры или функции включая схему"}}, "required": ["routinename"]}}},
    {"type": "function", "function": {"name": "create_routine_description", "description": "Получить описание подпрограммы.", "parameters": {"type": "object", "properties": {"routinename": {"type": "string", "description": "Имя подпрограммы"}, "additional_info": {"type": "string", "description": "Дополнительная информация"}}, "required": ["routinename"]}}}
]

# Парсинг командной строки
def parse_args():
    parser = argparse.ArgumentParser(description="SQL-агент с поддержкой стартового промпта")
    parser.add_argument("-p", "--prompt-file", type=str, help="Путь к текстовому файлу с промптом")
    parser.add_argument("-l", "--object-list", type=str, help="Список имен объектов для обработки.")
    return parser.parse_args()

# Базовая папка для работы агента
AIFILES_DIR = Path.cwd()
AIFILES_DIR.mkdir(exist_ok=True)

def _check_path(filename: str) -> Path:
    path = Path(filename)
    if path.is_absolute():
        resolved = path.resolve()
    else:
        resolved = (AIFILES_DIR / path).resolve()
    if not resolved.is_relative_to(AIFILES_DIR):
        raise ValueError(f"Доступ только к файлам внутри текущей папки")
    return resolved

def read_file(filename: str) -> str:
    return _check_path(AIFILES_DIR / filename).read_text(encoding='utf-8')

def write_file(filename: str, content: str) -> None:
    path = _check_path(AIFILES_DIR / filename)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')

def copy_file(source: str, destination: str) -> None:
    src_path = _check_path(source)
    dest_path = _check_path(destination)
    if not src_path.is_file():
        raise Error(f"Not exist file '{src_path}'")
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src_path, dest_path)

def agent_file_list(folder: str, mask: str) -> list[dict]:
    current_dir = AIFILES_DIR / folder
    directory = _check_path(current_dir)
    result = []
    for file in directory.glob(mask):
        if not file.is_file(): continue
        h = hashlib.blake2b(digest_size=4)
        size = file.stat().st_size
        with open(file, 'rb') as f:
            for chunk in iter(lambda: f.read(65536), b""): h.update(chunk)
        result.append({"name": str(file.relative_to(current_dir)), "size": size, "hash": h.hexdigest()})
    return result

def agent_exist_file(filename: str) -> str: return str(_check_path(AIFILES_DIR / filename).is_file())

def agent_read_file(filename: str) -> str:
    try: return {"status": "success", "content": read_file(filename)}
    except Exception as e: return {"status": "error", "message": str(e)}

def agent_read_lines(filename: str, first_line: int | None, last_line: int | None) -> List[str]:
    try:
        str_list = read_file(filename).split('\n')
        return {"status": "success", "content": str_list[first_line:last_line]}
    except Exception as e: return {"status": "error", "message": str(e)}

def agent_write_file(filename: str, content: str) -> str:
    try:
        write_file(filename, content)
        return {"status": "success", "message": f"Файл '{filename}' успешно записан."}
    except Exception as e: return {"status": "error", "message": str(e)}

def agent_copy_file(source: str, destination: str) -> str:
    try:
        copy_file(source, destination)
        return {"status": "success", "message": f"Файл '{source}' успешно скопирован."}
    except Exception as e: return {"error", str(e)}

# Загрузка системного промпта
if not _check_path(AIFILES_DIR / "AGENTS.md").is_file():
    console.print("[bold red]Файл AGENTS.md в текущей папке отсутствует[/bold red]")
    exit()
SYSTEM_PROMPT = read_file("AGENTS.md")

# Работа с PostgreSQL
def get_db_connection(): return psycopg2.connect(**TEAM_DB_CONFIG)

def create_new_session(owner_session_id: str = None) -> str:
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO chat_session (owner_id) VALUES (%s) RETURNING id", (owner_session_id,))
            return str(cur.fetchone()[0])

def save_message(session_id: str, role: str, action: str, content: str, tool_call_id: str = None):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO chat_message (session_id, role, action, content, tool_call_id) VALUES (%s, %s, %s, %s, %s)",
                        (session_id, role, action, content, tool_call_id))

def exec_sql(query: str, params: list = None) -> list:
    with psycopg2.connect(**TEST_DB_CONFIG) as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            conn.commit()
            records = cur.fetchall()
            result = []
            for row in records:
                result.append({k: str(v) if isinstance(v, (datetime.date, datetime.datetime, uuid.UUID)) else v for k, v in row.items()})
            return result

def execute_sql_query(query: str) -> str:
    def _check_sql(query: str):
        content = re.sub(r'/\*.*?\*/', '', query, flags=re.DOTALL)
        cleaned_lines = []
        for line in content.splitlines():
            l = line.lstrip()
            if l.startswith("--"): continue
            l = l.upper()
            if l:
                if not l.startswith(("SELECT", "CALL", "INSERT", "UPDATE", "DELETE", "WITH")):
                    raise Error(f"Разрешены только запросы CALL, SELECT, INSERT, UPDATE, DELETE или CTE\n\n'''\n{l}\n```\n")
                else: return
        raise Error("Текст не содержит SQL-запроса")
    try:
        _check_sql(query)
        return exec_sql(query)
    except Error as e:
        if str(e).lower() == 'no results to fetch': return {"execute": str(e)}
        return {"error": str(e)}

def get_table_def_from_db(tablename: str) -> str:
    Result = {}
    try:
        Result['table'] = exec_sql("SELECT obj_description(%s::regclass)", (tablename,))
        Result['columns'] = exec_sql("""
            SELECT a.attname AS column_name, format_type(a.atttypid, a.atttypmod) AS data_type,
                   pg_get_expr(d.adbin, d.adrelid) AS default_value, col_description(a.attrelid, a.attnum) AS comment,
                   concat_ws(', ', CASE WHEN a.attnotnull THEN 'NOT NULL' END,
                       (SELECT string_agg(CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'c' THEN 'CHECK' END, ', ')
                        FROM pg_catalog.pg_constraint con WHERE con.conrelid = a.attrelid AND a.attnum = ANY(con.conkey))) AS constraints
            FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;""", (tablename,))
        Result['indexes'] = exec_sql("SELECT indexdef AS index_definition FROM pg_indexes WHERE schemaname = %s AND tablename = %s", tablename.split('.'))
        Result['triggers'] = exec_sql("""
            SELECT t.tgname AS trigger_name, CASE (t.tgtype::int & 3) WHEN 1 THEN 'BEFORE' WHEN 2 THEN 'AFTER' WHEN 3 THEN 'INSTEAD OF' END AS timing,
                   ARRAY_TO_STRING(ARRAY[CASE WHEN (t.tgtype::int & 4) <> 0 THEN 'INSERT' END, CASE WHEN (t.tgtype::int & 16) <> 0 THEN 'UPDATE' END,
                                   CASE WHEN (t.tgtype::int & 8) <> 0 THEN 'DELETE' END, CASE WHEN (t.tgtype::int & 32) <> 0 THEN 'TRUNCATE' END], ' OR ') AS events,
                   p.proname AS function_name
            FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid JOIN pg_proc p ON t.tgfoid = p.oid 
            WHERE tgrelid = %s::regclass AND tgisinternal = false""", (tablename,))
        return Result
    except Error as e:
        if str(e).lower() == 'no results to fetch': return {}
        return {"error": str(e)}

def get_routine_def_from_db(routinename: str) -> str:
    if not routinename: return {"error": "Передан пустой параметр routinename"}
    params = routinename.split('.')
    try:
        return exec_sql("""
            SELECT p.proname AS "name", n.nspname AS "schema",
                   CASE p.prokind WHEN 'f' THEN 'function' WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window' END ||
                   CASE WHEN t.typname = 'trigger' THEN ' (trigger)' WHEN t.typname = 'event_trigger' THEN ' (event_trigger)' ELSE '' END AS "routine_type",
                   obj_description(p.oid, 'pg_proc') AS "comment", pg_get_functiondef(p.oid) AS "def"
            FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid JOIN pg_catalog.pg_type t ON p.prorettype = t.oid
            WHERE n.nspname = %s AND p.proname = %s;""", (params[0], '.'.join(params[1:])))
    except Error as e:
        if str(e).lower() == 'no results to fetch': return '{}'
        return {"error": str(e)}

def model_response(session_id: str, messages: list) -> str:

    def process_stream(response_stream):
        content_parts = []
        completed_reasoning_blocks = []
        current_reasoning_buffer = ""
        current_content_buffer = ""
        tool_calls_accumulator = {}
        with Live("", console=console, refresh_per_second=10, vertical_overflow="visible") as live:

            for chunk in response_stream:
                delta = chunk.choices[0].delta

                # 1. Обработка размышлений
                if hasattr(delta, 'reasoning_content') and delta.reasoning_content:

                    completed_reasoning_blocks.append(delta.reasoning_content)
                    current_reasoning_buffer += delta.reasoning_content
                    live.update(Group(Markdown(f"{current_reasoning_buffer}", style="dim italic cyan")))

                    while '\n\n' in current_reasoning_buffer:                                     # Если в буфере появился разделитель блоков (двойной перевод строки)
                        idx = current_reasoning_buffer.find('\n\n')
                        completed_block = current_reasoning_buffer[:idx].strip()
                        live.console.print(Markdown(f"{completed_block}", style="dim italic cyan"))  # Выводим завершенный блок статично НАД Live (с пустой строкой в начале)
                        current_reasoning_buffer = current_reasoning_buffer[idx+2:].strip()          # Убираем обработанную часть из буфера

                        if not current_reasoning_buffer:
                            live.console.print(Text(""))

                    continue

                elif current_reasoning_buffer:                                                    # Размышления закончились - закончить блок размышлений если что то осталось
                    live.update(Group(Markdown("")))
                    live.console.print(Markdown(f"{current_reasoning_buffer}", style="dim italic cyan"))
                    current_reasoning_buffer = ""

                # 2. Накопление основного текста
                if delta.content:

                    if not current_content_buffer:
                        live.console.print(Text(""))

                    content_parts.append(delta.content)
                    current_content_buffer += delta.content
                    live.update(Group(Markdown(f"{current_content_buffer}")))

                    while '\n\n' in current_content_buffer:                                       # Разбивка на блоки по двойному переводу строки (как для размышлений)
                        idx = current_content_buffer.find('\n\n')
                        completed_block = current_content_buffer[:idx].strip()
                        live.console.print(Markdown(f"{completed_block}"))
                        current_content_buffer = current_content_buffer[idx+2:].strip()           # Убираем обработанную часть из буфера

                    continue

                elif current_content_buffer:                                                      # Основной текст закончился
                    live.update(Group(Markdown("")))
                    live.console.print(Markdown(f"{current_content_buffer}"))
                    current_content_buffer = ""

                # 3. Накопление аргументов вызова инструментов
                if delta.tool_calls:
                    for tc in delta.tool_calls:
                        idx = tc.index
                        if idx not in tool_calls_accumulator:
                            tool_calls_accumulator[idx] = {"id": tc.id, "type": "function", "function": {"name": tc.function.name or "", "arguments": ""}}
                        if tc.function.arguments:
                            tool_calls_accumulator[idx]["function"]["arguments"] += tc.function.arguments

            # --- Обработка остатков буферов после завершения стрима ---
            if current_reasoning_buffer:
                live.update(Group(Markdown("")))
                live.console.print(Markdown(f"{current_reasoning_buffer}", style="dim italic cyan"))
                current_reasoning_buffer = ""
            if current_content_buffer:
                live.update(Group(Markdown(f"")))
                live.console.print(Markdown(f"{current_content_buffer}"))
                current_content_buffer = ""

        # Формируем итоговое сообщение
        final_message = {"role": "assistant", "content": "".join(content_parts) if content_parts else None}
        # Восстанавливаем полный текст рассуждений из завершенных блоков
        if completed_reasoning_blocks:
            final_message["reasoning_content"] = "\n\n".join(completed_reasoning_blocks)

            
        if tool_calls_accumulator:
            final_message["tool_calls"] = [tool_calls_accumulator[i] for i in sorted(tool_calls_accumulator.keys())]
            
        return final_message


    response_stream = client.chat.completions.create(
        model=MODEL, messages=messages, tools=tools, tool_choice="auto",
        temperature=TEMPERATURE, extra_body={"enable_thinking": True}, stream=True
    )
    response_message = process_stream(response_stream)

    while response_message.get("tool_calls"):
        if response_message.get("reasoning_content"):
            save_message(session_id, "agent", "thinking", response_message["reasoning_content"])
        messages.append(response_message)
        
        for tool_call in response_message["tool_calls"]:
            func_name = tool_call["function"]["name"]
            args = json.loads(tool_call["function"]["arguments"])
            result = ""
            
            # --- Dispatch инструментов с красивым выводом ---
            if func_name == "get_table_def_from_db":
                tablename = args.get("tablename")
                save_message(session_id, "table_def", 'query', tablename, tool_call["id"])
                console.print(Panel(f"[bold]{tablename}[/bold]", title="get_table_def_from_db", border_style="blue"))
                result = get_table_def_from_db(tablename)
            elif func_name == "get_routine_def_from_db":
                routinename = args.get("routinename")
                save_message(session_id, "routine_def", 'query', routinename, tool_call["id"])
                console.print(Panel(f"[bold]{routinename}[/bold]", title="get_routine_def_from_db", border_style="blue"))
                result = get_routine_def_from_db(routinename)
            elif func_name == "execute_sql_query":
                query = args.get("query")
                save_message(session_id, "sql", 'query', query, tool_call["id"])
                console.print(Panel(Syntax(query, "sql", theme="monokai", line_numbers=True), title="execute_sql_query", border_style="yellow"))
                result = execute_sql_query(query)
            elif func_name == "exist_file":
                filename = args.get("filename")
                save_message(session_id, "exist_file", 'request', filename, tool_call["id"])
                console.print(Panel(f"[bold]{filename}[/bold]", title="exist_file", border_style="cyan"))
                result = agent_exist_file(filename)
            elif func_name == "file_list":
                folder, mask = args.get("folder"), args.get("mask")
                save_message(session_id, "file_list", 'request', str(Path(folder)/mask), tool_call["id"])
                console.print(Panel(f"[bold]{folder}/{mask}[/bold]", title="file_list", border_style="cyan"))
                result = agent_file_list(folder, mask)
            elif func_name == "read_text_file":
                filename = args.get("filename")
                save_message(session_id, "read_text_file", 'request', filename, tool_call["id"])
                console.print(Panel(f"[bold]{filename}[/bold]", title="read_text_file", border_style="cyan"))
                result = agent_read_file(filename)
            elif func_name == "read_lines":
                filename, first_line, last_line = args.get("filename"), args.get("first_line"), args.get("last_line")
                save_message(session_id, "read_lines", 'request', f"{filename}: {first_line}: {last_line}", tool_call["id"])
                console.print(Panel(f"[bold]{filename}[/bold] ({first_line}:{last_line})", title="read_lines", border_style="cyan"))
                result = agent_read_lines(filename, first_line, last_line)
            elif func_name == "write_text_file":
                filename, content = args.get("filename"), args.get("content")
                save_message(session_id, "file", 'write_request', f"{filename}: {content[:100]}...", tool_call["id"])
                console.print(Panel(f"[bold]{filename}[/bold]", title="write_text_file", border_style="magenta"))
                result = agent_write_file(filename, content)
            elif func_name == "copy_file":
                source, destination = args.get("source"), args.get("destination")
                save_message(session_id, "file", 'copy_request', f"{source} -> {destination}", tool_call["id"])
                console.print(Panel(f"[bold]{source} -> {destination}[/bold]", title="copy_file", border_style="magenta"))
                result = agent_copy_file(source, destination)
            elif func_name == "create_routine_description":
                routinename, additional_info = args.get("routinename"), args.get("additional_info")
                save_message(session_id, "description", 'request', f"{routinename}: {additional_info}", tool_call["id"])
                console.print(Panel(f"[bold]{routinename}[/bold]\n{additional_info}", title="create_routine_description", border_style="green"))
                result = create_routine_description(session_id, routinename, additional_info)
            else:
                result = {"error": f"Неизвестный инструмент {func_name}"}

            # result_str - ПОЛНЫЙ JSON для передачи в LLM
            result_str = json.dumps(result, indent=4, ensure_ascii=False, default=str)
            save_message(session_id, func_name, 'result', result_str, tool_call["id"])
            
            # --- ОГРАНИЧЕНИЕ ВЫВОДА JSON В КОНСОЛЬ ДО 16 СТРОК ---
            lines = result_str.split('\n')
            if len(lines) > 16:
                # 8 строк сверху, 1 строка "...", 7 строк снизу = 16 строк
                display_lines = lines[:8] + ['    ...'] + lines[-7:]
                result_str_display = '\n'.join(display_lines)
            else:
                result_str_display = result_str
                
            # Красивый вывод усеченного JSON
            console.print(Panel(Syntax(result_str_display, "json", theme="monokai"), title=f"Result: {func_name}", border_style="green", expand=False))
            
            # В контекст модели добавляем ПОЛНУЮ строку
            messages.append({"role": "tool", "tool_call_id": tool_call["id"], "content": result_str})

        response_stream = client.chat.completions.create(
            model=MODEL, messages=messages, tools=tools, temperature=TEMPERATURE, stream=True
        )
        response_message = process_stream(response_stream)

    agent_message = response_message.get("content", "")
    save_message(session_id, "agent", "response", agent_message)
    messages.append({"role": "assistant", "content": agent_message})
    return agent_message

def proceed(prompt: str, owner_session_id: str = None, additional_info: str = None) -> str:
    session_id = create_new_session(owner_session_id)
    console.print(f"\n[dim]Session ID: {session_id}[/dim]")
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    save_message(session_id, "system", None, messages[0]["content"])
    save_message(session_id, "user", "content", prompt)
    messages.append({"role": "user", "content": prompt})
    if additional_info:
        save_message(session_id, "user", "content", additional_info)
        messages.append({"role": "user", "content": additional_info})
    return model_response(session_id, messages)

def proceed_object(objectname: str, prompt_file: Path, owner_session_id: str = None, additional_info: str = None) -> str:
    try: prompt = prompt_file.read_text(encoding="utf-8").replace('<objectname>', objectname)
    except FileNotFoundError: return json.dumps({"error": f"Prompt file not exist {prompt_file}"}, ensure_ascii=False)
    
    console.print(f"[bold yellow]--- Обработка объекта: {objectname} ---[/bold yellow]")
    if not owner_session_id: save_message(None, "objectname", f"{objectname}", additional_info)
    response = proceed(prompt, owner_session_id, additional_info)
    console.print("[bold yellow]-------------------------[/bold yellow]")
    return response

def create_routine_description(owner_session_id: str, routinename: str, additional_info: str = None) -> str:
    script_dir = Path(__file__).resolve().parent
    file_path = script_dir / "create_routine_description.md"
    return proceed_object(routinename, file_path, owner_session_id, additional_info)

if __name__ == "__main__":
    args = parse_args()
    if not args.prompt_file: raise FileNotFoundError(f"Ошибка: файл с промптом не указан")
    
    prompt_path = Path(args.prompt_file)
    if not prompt_path.exists() or not prompt_path.is_file():
        raise FileNotFoundError(f"Ошибка: файл '{args.prompt_file}' не найден")
        
    console.print(f"\n[bold]Модель:[/bold] {MODEL}")
    console.print(f"[bold]Промпт:[/bold] {prompt_path}")
    
    if args.object_list:
        list_path = Path(args.object_list)
        if list_path.exists() and list_path.is_file():
            obj_list = list_path.read_text(encoding='utf-8').strip()
            console.print(f"[dim]Загружен список объектов из: {list_path}[/dim]")
            is_first = True
            for s in sorted(set(obj_list.split('\n'))):
                if s:
                    if not is_first: console.print("[bold red]<***CLEAR***>[/bold red]")
                    is_first = False
                    l = s.split(':')
                    objectname = l[0].strip()
                    additional_info = l[1].strip() if len(l) > 1 else None
                    proceed_object(objectname, prompt_path, None, additional_info)
        else: raise FileNotFoundError(f"Ошибка: файл '{args.object_list}' не найден")
    else:
        #console.print("[bold]## Новая сессия[/bold]")
        response = proceed(prompt_path.read_text(encoding="utf-8"))
        
    console.print("\n[bold green]Работа агента закончена[/bold green]")
