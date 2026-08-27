# Transforma o CSV de cadastro do salao no payload de site_import_clients.
import csv, json, re, sys, collections, os

ORIGEM = "/root/.claude/uploads/5baf539b-79e4-53e2-af48-b6282919d29f/8c678c20-10__CADASTRO_DE_CLIENTES.csv"
DESTINO = os.path.dirname(os.path.abspath(__file__))

# Familia por categoria. A familia existe para mudar a CONVERSA: COR exige
# teste de mechas, ALISAMENTO ocupa bloco longo, CORTE e curto e sem quimica.
FAMILIA = {
    'Luzes/Mechas': 'COR', 'Coloração': 'COR', 'Gloss': 'COR', 'Tonalizante': 'COR',
    'Morena Iluminada': 'COR', 'Retoque de raiz': 'COR', 'Matizar': 'COR',
    'Progressiva': 'ALISAMENTO', 'Selante': 'ALISAMENTO', 'Progressiva Violet': 'ALISAMENTO',
    'Progressiva sem formol': 'ALISAMENTO', 'Selante sem formol': 'ALISAMENTO',
    'Selante com formol': 'ALISAMENTO', 'Progressiva orgânica': 'ALISAMENTO',
    'Progressiva japonesa': 'ALISAMENTO', 'Escova orgânica': 'ALISAMENTO',
    'Hidratação': 'TRATAMENTO', 'Joico/Blondorplex': 'TRATAMENTO', 'Metal Detox': 'TRATAMENTO',
    'Cronograma capilar': 'TRATAMENTO', 'Botox': 'TRATAMENTO', 'Fioterapia': 'TRATAMENTO',
    'Ozônio': 'TRATAMENTO',
    'Corte': 'CORTE', 'Escova': 'CORTE',
    'Penteado/Make': 'OUTRO',
}

PREFIXO_FAMILIA = {'Cor': 'COR', 'Alisamento': 'ALISAMENTO', 'Tratamento': 'TRATAMENTO', 'Corte': 'CORTE'}
UNIDADE_DIAS = {'dia': 1, 'dias': 1, 'semana': 7, 'semanas': 7, 'mes': 30, 'mês': 30, 'meses': 30}


def data_iso(br):
    br = (br or '').strip()
    m = re.match(r'^(\d{2})/(\d{2})/(\d{4})$', br)
    return f'{m.group(3)}-{m.group(2)}-{m.group(1)}' if m else None


def confianca(vezes):
    # Uma visita nao e cadencia. Duas ou tres sao indicio. Quatro ja e habito.
    return 'ALTA' if vezes >= 4 else ('MEDIA' if vezes >= 2 else 'BAIXA')


def ler_cadencias(texto):
    """'Cor (Luzes/Mechas) a cada ~3 meses | Tratamento a cada ~7 dias'
    -> [(familia, [rotulos] ou None, dias)]"""
    saida = []
    for trecho in (texto or '').split('|'):
        trecho = trecho.strip()
        if not trecho:
            continue
        m = re.match(r'^(\w+)\s*(?:\(([^)]*)\))?\s*a cada\s*~?([\d.,]+)\s*(\w+)', trecho)
        if not m:
            continue
        familia = PREFIXO_FAMILIA.get(m.group(1))
        if not familia:
            continue
        rotulos = [r.strip() for r in m.group(2).split('/')] if m.group(2) else None
        try:
            quantidade = float(m.group(3).replace(',', '.'))
        except ValueError:
            continue
        dias = UNIDADE_DIAS.get(m.group(4).lower())
        if not dias:
            continue
        total = int(round(quantidade * dias))
        if total > 0:
            saida.append((familia, rotulos, total))
    return saida


linhas, avisos = [], collections.Counter()
with open(ORIGEM, encoding='utf-8-sig') as f:
    for reg in csv.DictReader(f, delimiter=';'):
        fone = re.sub(r'[^0-9]', '', reg['Telefone'] or '')
        if len(fone) < 10:
            avisos['telefone_curto'] += 1

        procedimentos = {}
        for parte in (reg['ProcedimentosMaisFaz'] or '').split(';'):
            parte = parte.strip()
            if not parte:
                continue
            m = re.match(r'^(.*?)\s*x(\d+)$', parte)
            rotulo = (m.group(1) if m else parte).strip()
            vezes = int(m.group(2)) if m else 1
            familia = FAMILIA.get(rotulo)
            if familia is None:
                avisos['categoria_' + rotulo] += 1
                familia = 'OUTRO'
            procedimentos[(familia, rotulo)] = {
                'family': familia, 'label': rotulo, 'timesDone': vezes,
                'cadenceConfidence': confianca(vezes),
            }

        for familia, rotulos, dias in ler_cadencias(reg['LogicaDaCliente']):
            for (fam, rot), proc in procedimentos.items():
                if fam == familia and (rotulos is None or rot in rotulos):
                    proc['cadenceDays'] = dias

        ultimo = (reg['UltimoProcedimento'] or '').strip()
        familia_ultima = next(
            (FAMILIA[c] for c in sorted(FAMILIA, key=len, reverse=True)
             if c.lower() in ultimo.lower()), None)

        linha = {
            'phone': reg['Telefone'].strip(),
            'name': reg['Cliente'].strip(),
            'lastVisitOn': data_iso(reg['UltimaVisita']),
            'lastProcedure': ultimo[:200] or None,
            'lastFamily': familia_ultima,
            'toneCited': (reg['TomCitado'] or '').strip() or None,
            'procedures': list(procedimentos.values()),
        }
        linhas.append({k: v for k, v in linha.items() if v not in (None, '', [])})

for i in range(0, len(linhas), 72):
    lote = linhas[i:i + 72]
    caminho = os.path.join(DESTINO, f'lote{i // 72 + 1}.json')
    with open(caminho, 'w', encoding='utf-8') as f:
        json.dump({'rows': lote}, f, ensure_ascii=False, separators=(',', ':'))
    print(f'{os.path.basename(caminho)}: {len(lote)} linhas, {os.path.getsize(caminho)} bytes')

print('\ntotal:', len(linhas))
print('avisos:', dict(avisos) or 'nenhum')
print('\namostra:')
print(json.dumps(linhas[1], ensure_ascii=False, indent=2))
