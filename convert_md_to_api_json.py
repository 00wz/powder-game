#!/usr/bin/env python3
"""
Конвертер экспортированной истории Roo Code из Markdown в api_conversation_history.json
"""

import json
import re
import time
import uuid

def generate_tool_id():
    """Генерирует уникальный ID для tool_use"""
    return f"toolu_{uuid.uuid4().hex[:24]}"

def parse_markdown_to_api_format(md_content):
    """Парсит markdown и возвращает список сообщений в формате api_conversation_history.json"""
    messages = []
    
    # Разбиваем по разделителям сообщений
    parts = re.split(r'\n---\n', md_content)
    
    # Начальный timestamp
    base_ts = int(time.time() * 1000) - len(parts) * 10000
    msg_index = 0
    
    current_tool_id = None
    
    for part in parts:
        part = part.strip()
        if not part:
            continue
        
        # Определяем тип сообщения
        if part.startswith('**Assistant:**'):
            # Сообщение ассистента
            content = part.replace('**Assistant:**', '', 1).strip()
            content_blocks = []
            
            # Проверяем наличие [Reasoning] блока
            reasoning_match = re.search(r'\[Reasoning\]\s*(.*?)(?=\[Tool Use:|$)', content, re.DOTALL)
            if reasoning_match:
                reasoning_text = reasoning_match.group(1).strip()
                content_blocks.append({
                    "type": "reasoning",
                    "text": reasoning_text,
                    "summary": []
                })
            
            # Проверяем наличие [Tool Use:] блока
            tool_match = re.search(r'\[Tool Use:\s*(\w+)\]\s*(.*?)(?=\n---|$)', content, re.DOTALL)
            if tool_match:
                tool_name = tool_match.group(1)
                tool_params_text = tool_match.group(2).strip()
                
                # Парсим параметры
                tool_input = {}
                current_key = None
                current_value_lines = []
                
                for line in tool_params_text.split('\n'):
                    # Проверяем, это новый ключ или продолжение значения
                    key_match = re.match(r'^([A-Za-z_]+):\s*(.*)', line)
                    if key_match:
                        # Сохраняем предыдущий ключ
                        if current_key:
                            tool_input[current_key.lower()] = '\n'.join(current_value_lines)
                        current_key = key_match.group(1)
                        current_value_lines = [key_match.group(2)] if key_match.group(2) else []
                    elif current_key:
                        current_value_lines.append(line)
                
                # Сохраняем последний ключ
                if current_key:
                    tool_input[current_key.lower()] = '\n'.join(current_value_lines)
                
                # Специальная обработка для некоторых инструментов
                if tool_name == 'read_file' and 'files' in tool_input:
                    try:
                        tool_input['files'] = json.loads(tool_input['files'])
                    except:
                        pass
                
                if tool_name == 'ask_followup_question' and 'follow_up' in tool_input:
                    try:
                        tool_input['follow_up'] = json.loads(tool_input['follow_up'])
                    except:
                        pass
                
                current_tool_id = generate_tool_id()
                content_blocks.append({
                    "type": "tool_use",
                    "id": current_tool_id,
                    "name": tool_name,
                    "input": tool_input
                })
            
            if content_blocks:
                messages.append({
                    "role": "assistant",
                    "content": content_blocks,
                    "ts": base_ts + msg_index * 1000
                })
                msg_index += 1
        
        elif part.startswith('**User:**'):
            # Сообщение пользователя
            content = part.replace('**User:**', '', 1).strip()
            content_blocks = []
            
            # Проверяем, это результат инструмента или обычное сообщение
            if content.startswith('[Tool]'):
                tool_content = content.replace('[Tool]', '', 1).strip()
                
                # Извлекаем JSON или текстовый результат
                json_match = re.search(r'\{.*?\}', tool_content, re.DOTALL)
                
                content_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": current_tool_id or generate_tool_id(),
                    "content": tool_content
                })
            elif content.startswith('[ERROR]'):
                # Сообщение об ошибке
                content_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": current_tool_id or generate_tool_id(),
                    "content": content
                })
            else:
                # Обычное сообщение пользователя
                # Извлекаем user_message если есть
                user_msg_match = re.search(r'<user_message>\s*(.*?)\s*</user_message>', content, re.DOTALL)
                if user_msg_match:
                    user_text = user_msg_match.group(1).strip()
                else:
                    # Удаляем технические блоки
                    user_text = re.sub(r'<environment_details>.*?</environment_details>', '', content, flags=re.DOTALL)
                    user_text = re.sub(r'# Reminder:.*?(?=\n---|$)', '', user_text, flags=re.DOTALL)
                    user_text = user_text.strip()
                
                if user_text:
                    content_blocks.append({
                        "type": "text",
                        "text": f"<user_message>\n{user_text}\n</user_message>"
                    })
                
                # Добавляем environment_details если есть
                env_match = re.search(r'<environment_details>(.*?)</environment_details>', content, re.DOTALL)
                if env_match:
                    content_blocks.append({
                        "type": "text", 
                        "text": f"<environment_details>{env_match.group(1)}</environment_details>"
                    })
            
            if content_blocks:
                messages.append({
                    "role": "user",
                    "content": content_blocks,
                    "ts": base_ts + msg_index * 1000
                })
                msg_index += 1
    
    return messages


def main():
    # Пути к файлам
    md_path = r"C:\Users\p.teslenko\Downloads\roo_task_jan-30-2026_12-46-16-pm.md"
    json_path = r"C:\Users\p.teslenko\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\tasks\019c0efe-9b55-7439-88d9-84493a79ed95\api_conversation_history.json"
    
    # Читаем markdown
    with open(md_path, 'r', encoding='utf-8') as f:
        md_content = f.read()
    
    # Конвертируем
    messages = parse_markdown_to_api_format(md_content)
    
    print(f"Сконвертировано {len(messages)} сообщений")
    
    # Записываем JSON
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(messages, f, ensure_ascii=False, indent=2)
    
    print(f"Результат записан в {json_path}")


if __name__ == "__main__":
    main()
