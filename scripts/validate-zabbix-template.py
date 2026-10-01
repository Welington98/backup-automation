#!/usr/bin/env python3
"""Valida arquivos de export do Zabbix (devops/zabbix/*.xml):

- XML bem formado.
- Todo elemento <uuid> tem 32 hex chars e e um UUIDv4 valido (Zabbix
  rejeita a importacao com "Invalid parameter '/N/uuid': UUIDv4 is
  expected." caso contrario - ja aconteceu neste repositorio).
- Nenhum <uuid> duplicado dentro do mesmo arquivo (duplicados tambem
  fazem a importacao falhar).

Uso: scripts/validate-zabbix-template.py [arquivo.xml ...]
Sem argumentos, valida todo devops/zabbix/*.xml.
"""
import glob
import re
import sys
import uuid
import xml.etree.ElementTree as ET

UUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def validate_file(path: str) -> list[str]:
    errors: list[str] = []

    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [f"{path}: XML malformado: {exc}"]

    seen: dict[str, str] = {}
    for elem in tree.getroot().iter("uuid"):
        raw = (elem.text or "").strip()
        location = elem.tag

        if not UUID_RE.match(raw):
            errors.append(
                f"{path}: uuid '{raw}' nao tem 32 caracteres hexadecimais"
            )
            continue

        formatted = f"{raw[0:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:32]}"
        parsed = uuid.UUID(formatted)
        if parsed.version != 4:
            versao = parsed.version if parsed.version is not None else "indefinida"
            errors.append(
                f"{path}: uuid '{formatted}' nao e UUIDv4 (versao "
                f"detectada: {versao}) - Zabbix rejeita a importacao com "
                f"\"Invalid parameter '/N/uuid': UUIDv4 is expected.\""
            )

        if raw in seen:
            errors.append(f"{path}: uuid '{formatted}' duplicado no arquivo")
        seen[raw] = location

    return errors


def main() -> int:
    paths = sys.argv[1:] or sorted(glob.glob("devops/zabbix/*.xml"))

    if not paths:
        print("Nenhum arquivo .xml encontrado em devops/zabbix/ para validar.")
        return 0

    all_errors: list[str] = []
    for path in paths:
        all_errors.extend(validate_file(path))

    if all_errors:
        print("Validacao dos templates Zabbix falhou:\n")
        for err in all_errors:
            print(f"  - {err}")
        return 1

    print(f"OK: {len(paths)} template(s) Zabbix validado(s) sem erros.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
