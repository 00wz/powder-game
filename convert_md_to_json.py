#!/usr/bin/env python3
"""
Конвертер экспортированной истории Roo Code из Markdown в ui_messages.json
"""

import json
import re
import time

def parse_markdown_to_messages(md_content):
    """Парсит markdown и возвращает список сообщений в формате ui_messages.json"""
    messages = []
    
    # Разбиваем по разделителям сообщений
    parts = re.split(r'\n---\n', md_content)
    
    # Начальный timestamp (будем увеличивать для каждого сообщения)
    base_ts = int(time.time() * 1000) - len(parts) * 10000
    msg_index = 0
    
    for part in parts:
        part = part.strip()
        if not part:
            continue
        
        # Определяем тип сообщения
        if part.startswith('**Assistant:**'):
            # Сообщение ассистента
            content = part.replace('**Assistant:**', '', 1).strip()
            
            # Проверяем наличие [Reasoning] блока
            reasoning_match = re.search(r'\[Reasoning\]\s*(.*?)(?=\[Tool Use:|$)', content, re.DOTALL)
            if reasoning_match:
                reasoning_text = reasoning_match.group(1).strip()
                messages.append({
                    "ts": base_ts + msg_index * 1000,
                    "type": "say",
                    "say": "reasoning",
                    "text": reasoning_text,
                    "partial": False
                })
                msg_index += 1
            
            # Проверяем наличие [Tool Use:] блока
            tool_match = re.search(r'\[Tool Use:\s*(\w+)\]\s*(.*?)(?=\n---|\Z)', content, re.DOTALL)
            if tool_match:
                tool_name = tool_match.group(1)
                tool_params = tool_match.group(2).strip()
                
                # Парсим параметры
                params = {}
                for line in tool_params.split('\n'):
                    if ':' in line:
                        key, value = line.split(':', 1)
                        key = key.strip().lower()
                        value = value.strip()
                        if key == 'path':
                            params['path'] = value
                        elif key == 'content':
                            # Содержимое может быть многострочным
                            params['content'] = value
                        elif key == 'files':
                            try:
                                params['files'] = json.loads(value)
                            except:
                                params['files'] = value
                
                messages.append({
                    "ts": base_ts + msg_index * 1000,
                    "type": "say",
                    "say": "tool",
                    "text": json.dumps({"tool": tool_name, **params}),
                })
                msg_index += 1
            
            # Проверяем наличие attempt_completion
            completion_match = re.search(r'\[Tool Use:\s*attempt_completion\]\s*Result:\s*(.*?)(?=\n---|\Z)', content, re.DOTALL)
            if completion_match:
                result_text = completion_match.group(1).strip()
                messages.append({
                    "ts": base_ts + msg_index * 1000,
                    "type": "say",
                    "say": "completion_result",
                    "text": result_text,
                    "partial": False
                })
                msg_index += 1
            
            # Если это просто текст без инструментов
            if not tool_match and not completion_match:
                # Убираем блоки [Reasoning] если они были
                clean_content = re.sub(r'\[Reasoning\].*?(?=\n\n|\Z)', '', content, flags=re.DOTALL).strip()
                if clean_content:
                    messages.append({
                        "ts": base_ts + msg_index * 1000,
                        "type": "say",
                        "say": "text",
                        "text": clean_content,
                        "images": []
                    })
                    msg_index += 1
        
        elif part.startswith('**User:**'):
            # Сообщение пользователя
            content = part.replace('**User:**', '', 1).strip()
            
            # Удаляем технические блоки [ERROR], <environment_details> и т.д.
            content = re.sub(r'\[ERROR\].*?(?=\n\n|\Z)', '', content, flags=re.DOTALL)
            content = re.sub(r'<environment_details>.*?</environment_details>', '', content, flags=re.DOTALL)
            content = re.sub(r'# Reminder:.*?(?=\n---|\Z)', '', content, flags=re.DOTALL)
            content = content.strip()
            
            if content and not content.startswith('[Tool]'):
                # Проверяем наличие изображения
                has_image = '[Image]' in content
                content = content.replace('[Image]', '').strip()
                
                messages.append({
                    "ts": base_ts + msg_index * 1000,
                    "type": "say",
                    "say": "text",
                    "text": content,
                    "images": ["[image]"] if has_image else []
                })
                msg_index += 1
        
        elif part.startswith('[Tool]'):
            # Результат инструмента
            content = part.replace('[Tool]', '', 1).strip()
            
            # Извлекаем JSON если есть
            json_match = re.search(r'\{.*?\}', content, re.DOTALL)
            if json_match:
                messages.append({
                    "ts": base_ts + msg_index * 1000,
                    "type": "say",
                    "say": "tool",
                    "text": json_match.group(0),
                })
                msg_index += 1
    
    return messages


def main():
    # Пути к файлам
    md_path = r"C:\Users\p.teslenko\Downloads\roo_task_jan-30-2026_12-46-16-pm.md"
    json_path = r"C:\Users\p.teslenko\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\tasks\019c0ef8-5f93-76dd-9859-673925bf4fbf\ui_messages.json"
    
    # Читаем markdown
    with open(md_path, 'r', encoding='utf-8') as f:
        md_content = f.read()
    
    # Конвертируем
    messages = parse_markdown_to_messages(md_content)
    
    print(f"Сконвертировано {len(messages)} сообщений")
    
    # Записываем JSON
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(messages, f, ensure_ascii=False, indent=2)
    
    print(f"Результат записан в {json_path}")


if __name__ == "__main__":
    main()
