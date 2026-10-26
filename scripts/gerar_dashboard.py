#!/usr/bin/env python3
"""Gera o dashboard AI/BI do Projeto Farol: resources/dashboard-portfolio.lvdash.json.

Por quê um script e não o JSON escrito à mão: o JSON do AI/BI tem centenas de
linhas repetitivas (cada widget repete campo, encoding e posição). Aqui cada
widget é uma chamada de função, e o SQL de cada dataset aparece uma vez só.

Três páginas, uma por pergunta do dono:
  Portfólio     perguntas 1 e 2: quem está atrasado, de qual cliente, e quanto vai custar
  Pessoas       pergunta 3: gente parada enquanto outro projeto pede gente
  Fornecedores  pergunta 4: as entregas de consultoria que vão atrasar o próximo mês

Regras do dashboard:
  - As tabelas da gold vão com o nome PURO (FROM projeto_situacao_atual): o bundle
    preenche catálogo e schema (dataset_catalog / dataset_schema no recurso).
  - A silver.entregas_fornecedor vai com o nome completo: ela não está no schema gold.
  - Razão é SUM/SUM, nunca AVG de razão (o SPI da carteira pondera pelo tamanho do projeto).
  - "Hoje" é DATE'2026-10-16'. Nunca current_date().

Uso:
  python3 scripts/gerar_dashboard.py               grava o JSON
  python3 scripts/gerar_dashboard.py --sql <pasta> grava uma .sql por dataset, com
                                                   lakehouse_vertice.gold. na frente das
                                                   tabelas, para testar antes do deploy
"""
import argparse
import json
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SAIDA = RAIZ / "resources" / "dashboard-portfolio.lvdash.json"

TABELAS_GOLD = ["projeto_situacao_atual", "fato_projeto_semana", "utilizacao_pessoa_semana", "status_estruturado"]

# Cores da Jornada e as cores fixas da situação
AZUL, CIANO, FUNDO_ESCURO = "#0059DB", "#22C2F4", "#14141A"
CRITICO, ATENCAO, OK = "#FF5F46", "#F6C344", "#22C2F4"
CORES_SITUACAO = [
    {"value": "crítico", "color": CRITICO},
    {"value": "atenção", "color": ATENCAO},
    {"value": "ok", "color": OK},
]


# ---------------------------------------------------------------------------
# Datasets: o SQL de cada um. Um dataset por grão (projeto, semana, pessoa...).
# ---------------------------------------------------------------------------
DATASETS = {
    # Portfólio: um projeto em andamento por linha. Alimenta KPIs, dispersão e tabela.
    "ds_carteira": {
        "displayName": "Carteira em andamento",
        "sql": """
SELECT
  projeto_id,
  projeto,
  cliente,
  segmento,
  gerente_projeto,
  valor_contrato,
  orcamento,
  pv,
  ev,
  ac,
  spi,
  cpi,
  eac,
  estouro_previsto,
  margem_projetada,
  atraso_projetado_dias,
  situacao,
  farol_do_gerente,
  farol_calculado,
  IF(melancia, 'sim', 'não')                           AS melancia,
  IF(situacao IN ('atenção', 'crítico'), 1, 0)         AS em_risco,
  IF(situacao = 'crítico', 1, 0)                       AS critico,
  IF(melancia, 1, 0)                                   AS e_melancia
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
ORDER BY melancia DESC, spi
""",
        # Medidas do dataset: os KPIs são SUM/SUM sobre a carteira inteira
        "columns": [
            {"displayName": "Carteira", "description": "Soma do valor de contrato dos projetos em andamento (R$)",
             "expression": "SUM(`valor_contrato`)"},
            {"displayName": "SPI", "description": "SPI da carteira: soma do EV ÷ soma do PV (< 1 é atraso)",
             "expression": "SUM(`ev`) / SUM(`pv`)"},
            {"displayName": "CPI", "description": "CPI da carteira: soma do EV ÷ soma do AC (< 1 é estouro)",
             "expression": "SUM(`ev`) / SUM(`ac`)"},
            {"displayName": "Estouro previsto", "description": "Soma de EAC − orçamento, só onde é positivo (R$)",
             "expression": "SUM(`estouro_previsto`)"},
            {"displayName": "Projetos em risco", "description": "Projetos em atenção (SPI ou CPI < 0,9) ou críticos (< 0,8)",
             "expression": "SUM(`em_risco`)"},
            {"displayName": "Críticos", "description": "Projetos com SPI ou CPI < 0,8",
             "expression": "SUM(`critico`)"},
            {"displayName": "Melancias", "description": "Farol do gerente verde e SPI < 0,9",
             "expression": "SUM(`e_melancia`)"},
        ],
    },
    # Só os projetos que vão estourar: a barra não precisa de 16 barras zeradas
    "ds_estouro": {
        "displayName": "Estouro previsto por projeto",
        "sql": """
SELECT projeto, cliente, situacao, estouro_previsto
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
  AND estouro_previsto > 0
ORDER BY estouro_previsto DESC
""",
    },
    # SPI e CPI semanais da carteira: SUM/SUM por sexta
    "ds_semanal": {
        "displayName": "SPI e CPI semanais",
        "sql": """
SELECT
  semana,
  round(sum(ev) / sum(pv), 4) AS spi,
  round(sum(ev) / sum(ac), 4) AS cpi
FROM fato_projeto_semana
WHERE semana >= DATE'2025-03-07'
GROUP BY semana
ORDER BY semana
""",
    },
    # Pessoas: as 12 últimas semanas (31/07 a 16/10/2026), as 15 com mais custo parado
    "ds_pessoas_top": {
        "displayName": "Top 15 por custo da hora parada",
        "sql": """
SELECT
  concat(colaborador_id, ' · ', nome)                    AS pessoa,
  papel,
  round(sum(horas_ociosas), 0)                           AS horas_ociosas,
  round(sum(custo_ocioso), 2)                            AS custo_ocioso,
  round(sum(horas_apontadas) / sum(horas_disponiveis), 4) AS utilizacao
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY colaborador_id, nome, papel
ORDER BY custo_ocioso DESC
LIMIT 15
""",
    },
    # Pessoa × projeto nas mesmas 12 semanas, da mais parada à mais ocupada
    "ds_utilizacao": {
        "displayName": "Utilização por pessoa e projeto",
        "sql": """
SELECT
  colaborador_id,
  nome,
  papel,
  senioridade,
  projeto_id,
  round(sum(horas_disponiveis), 0)                         AS horas_disponiveis,
  round(sum(horas_apontadas), 0)                           AS horas_apontadas,
  round(sum(horas_ociosas), 0)                             AS horas_ociosas,
  round(sum(horas_apontadas) / sum(horas_disponiveis), 4)  AS utilizacao,
  round(sum(custo_ocioso), 2)                              AS custo_ocioso,
  max_by(spi_do_projeto, semana)                           AS spi_do_projeto
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY colaborador_id, nome, papel, senioridade, projeto_id
ORDER BY utilizacao, custo_ocioso DESC
""",
    },
    # Causas de bloqueio dos últimos 90 dias, nos 15 projetos com mais status bloqueados
    # (são 49 projetos com bloqueio: 49 barras não se leem)
    "ds_causas": {
        "displayName": "Causas de bloqueio por projeto",
        "sql": """
WITH bloqueados AS (
  SELECT projeto_id, causa_bloqueio, dias_impacto
  FROM status_estruturado
  WHERE data_status >= DATE'2026-07-18'
    AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
),
top_projetos AS (
  SELECT projeto_id, count(*) AS status_bloqueados
  FROM bloqueados
  GROUP BY projeto_id
  ORDER BY status_bloqueados DESC, projeto_id
  LIMIT 15
)
SELECT
  b.projeto_id,
  b.causa_bloqueio,
  count(*)                     AS status,
  coalesce(sum(b.dias_impacto), 0) AS dias_impacto
FROM bloqueados b
JOIN top_projetos t ON t.projeto_id = b.projeto_id
GROUP BY b.projeto_id, b.causa_bloqueio
""",
    },
    # Fornecedores: lidos direto da silver (fornecedor não tem tabela gold)
    "ds_fornecedores": {
        "displayName": "Entregas por fornecedor",
        "sql": """
SELECT
  fornecedor,
  count(DISTINCT fornecedor_como_veio)                                  AS grafias_no_cadastro,
  count(*)                                                              AS entregas,
  round(sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_real_dias END)
      / sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_prometido_dias END), 2) AS prazo_real_sobre_prometido,
  round(avg(CASE WHEN data_entrega IS NOT NULL
                 THEN IF(dias_de_atraso_na_entrega = 0, 1, 0) END), 4)  AS pct_no_prazo,
  count_if(em_atraso)                                                   AS em_atraso_hoje
FROM lakehouse_vertice.silver.entregas_fornecedor
GROUP BY fornecedor
ORDER BY em_atraso_hoje DESC, prazo_real_sobre_prometido DESC
""",
    },
    "ds_atrasadas": {
        "displayName": "Entregas em atraso hoje",
        "sql": """
SELECT
  entrega_id,
  projeto_id,
  fornecedor,
  item,
  valor,
  data_pedido,
  data_prometida,
  datediff(DATE'2026-10-16', data_prometida) AS dias_em_atraso
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE em_atraso
ORDER BY dias_em_atraso DESC
""",
    },
}


# ---------------------------------------------------------------------------
# Formatos
# ---------------------------------------------------------------------------
REAIS = {"type": "number-currency", "currencyCode": "BRL", "abbreviation": "compact",
         "decimalPlaces": {"type": "max", "places": 2}}
INDICE = {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}}
# KPI da carteira com 3 casas: o CPI é 0,96497, que com 2 casas viraria 0,96 e
# pareceria divergir do 0,97 de referência (que é 0,965 arredondado de novo)
INDICE_KPI = {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 3}}
PERCENT = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}
INTEIRO = {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 0}}


# ---------------------------------------------------------------------------
# Widgets: uma função por tipo. Cada uma devolve {"widget": ..., "position": ...}.
# ---------------------------------------------------------------------------
def pos(x, y, w, h):
    return {"x": x, "y": y, "width": w, "height": h}


def campo(coluna, agregacao=None):
    """Campo de query: o nome é o mesmo usado no encoding (regra do AI/BI)."""
    if agregacao is None:
        return {"name": coluna, "expression": f"`{coluna}`"}
    return {"name": f"{agregacao.lower()}({coluna})", "expression": f"{agregacao.upper()}(`{coluna}`)"}


def consulta(dataset, campos, desagregado):
    return [{"name": "main_query",
             "query": {"datasetName": dataset, "fields": campos, "disaggregated": desagregado}}]


def moldura(titulo, descricao=None):
    f = {"showTitle": True, "title": titulo}
    if descricao:
        f.update(showDescription=True, description=descricao)
    return f


def texto(nome, linhas, posicao):
    return {"widget": {"name": nome, "multilineTextboxSpec": {"lines": linhas}}, "position": posicao}


def kpi(nome, medida, titulo, formato, posicao, descricao=None):
    """Counter sobre uma medida do dataset ds_carteira (MEASURE)."""
    f = {"name": f"measure({medida})", "expression": f"MEASURE(`{medida}`)"}
    valor = {"fieldName": f["name"], "displayName": titulo}
    if formato:
        valor["format"] = formato
    return {"widget": {
        "name": nome,
        "queries": consulta("ds_carteira", [f], False),
        "spec": {"version": 2, "widgetType": "counter", "encodings": {"value": valor},
                 "frame": moldura(titulo, descricao)},
    }, "position": posicao}


def barra_horizontal(nome, dataset, categoria, valor, cor, titulo, formato, posicao,
                     mapeamento_cores=None, descricao=None, agregacao="SUM"):
    """Barra deitada: o valor no x, a categoria no y, ordenada pelo valor."""
    f_valor = campo(valor, agregacao)
    escala_cor = {"type": "categorical"}
    if mapeamento_cores:
        escala_cor["mappings"] = mapeamento_cores
    return {"widget": {
        "name": nome,
        "queries": consulta(dataset, [campo(categoria), campo(cor), f_valor], False),
        "spec": {
            "version": 3,
            "widgetType": "bar",
            "encodings": {
                "x": {"fieldName": f_valor["name"], "scale": {"type": "quantitative"},
                      "displayName": titulo.split(" por ")[0], "format": formato},
                "y": {"fieldName": categoria, "scale": {"type": "categorical", "sort": {"by": "value"}},
                      "displayName": categoria},
                "color": {"fieldName": cor, "scale": escala_cor, "displayName": cor},
            },
            "frame": moldura(titulo, descricao),
        },
    }, "position": posicao}


def linha_de_corte(eixo, valor, rotulo):
    tipo = "horizontal-line" if eixo == "y" else "vertical-line"
    return {"type": tipo, "encodings": {
        eixo: {"dataValue": str(valor), "dataType": "DOUBLE"},
        "label": {"value": rotulo},
        "color": {"value": CRITICO},
    }}


def tabela(nome, dataset, colunas, titulo, posicao, descricao=None):
    """colunas = [(campo, rótulo, formato ou None)]"""
    encodings = []
    for c, rotulo, formato in colunas:
        col = {"fieldName": c, "displayName": rotulo}
        if formato:
            col["format"] = formato
        encodings.append(col)
    return {"widget": {
        "name": nome,
        "queries": consulta(dataset, [campo(c) for c, _, _ in colunas], True),
        "spec": {"version": 2, "widgetType": "table", "encodings": {"columns": encodings},
                 "frame": moldura(titulo, descricao)},
    }, "position": posicao}


# ---------------------------------------------------------------------------
# Página 1 · Portfólio (perguntas 1 e 2)
# ---------------------------------------------------------------------------
portfolio = [
    texto("titulo_portfolio", [
        "## Quais projetos estão atrasados, e de quais clientes? Quanto esse atraso vai me custar?\n",
        "\n",
        "Fotografia de 16/10/2026 dos 41 projetos em andamento. SPI ou CPI abaixo de 0,9 = atenção, "
        "abaixo de 0,8 = crítico. **Melancia** = farol do gerente verde com SPI < 0,9.",
    ], pos(0, 0, 12, 2)),
    kpi("kpi_carteira", "Carteira", "Carteira em andamento", REAIS, pos(0, 2, 3, 3)),
    kpi("kpi_spi", "SPI", "SPI da carteira", INDICE_KPI, pos(3, 2, 3, 3), "Σ EV ÷ Σ PV · < 1 é atraso"),
    kpi("kpi_cpi", "CPI", "CPI da carteira", INDICE_KPI, pos(6, 2, 3, 3), "Σ EV ÷ Σ AC · < 1 é estouro"),
    kpi("kpi_estouro", "Estouro previsto", "Estouro previsto", REAIS, pos(9, 2, 3, 3), "EAC − orçamento, quando positivo"),
    kpi("kpi_risco", "Projetos em risco", "Projetos em risco", None, pos(0, 5, 4, 3), "atenção + crítico"),
    kpi("kpi_criticos", "Críticos", "Críticos", None, pos(4, 5, 4, 3), "SPI ou CPI < 0,8"),
    kpi("kpi_melancias", "Melancias", "Melancias", None, pos(8, 5, 4, 3), "farol verde e SPI < 0,9"),
    barra_horizontal("barra_estouro", "ds_estouro", "projeto", "estouro_previsto", "situacao",
                     "Estouro previsto por projeto", REAIS, pos(0, 8, 6, 8),
                     mapeamento_cores=CORES_SITUACAO, descricao="Só os projetos com EAC acima do orçamento"),
    {"widget": {
        "name": "dispersao_spi_cpi",
        "queries": consulta("ds_carteira", [campo("spi"), campo("cpi"), campo("situacao"), campo("projeto")], True),
        "spec": {
            "version": 3,
            "widgetType": "scatter",
            "encodings": {
                "x": {"fieldName": "spi", "scale": {"type": "quantitative"}, "displayName": "SPI", "format": INDICE},
                "y": {"fieldName": "cpi", "scale": {"type": "quantitative"}, "displayName": "CPI", "format": INDICE},
                "color": {"fieldName": "situacao", "displayName": "situação",
                          "scale": {"type": "categorical", "mappings": CORES_SITUACAO}},
                "extra": [{"fieldName": "projeto", "displayName": "projeto"}],
            },
            "annotations": [linha_de_corte("x", 0.9, "SPI 0,9"), linha_de_corte("y", 0.9, "CPI 0,9")],
            "frame": moldura("SPI × CPI por projeto", "Embaixo e à esquerda: atrasado e estourando"),
        },
    }, "position": pos(6, 8, 6, 8)},
    {"widget": {
        "name": "linha_spi_cpi_semanal",
        "queries": consulta("ds_semanal", [campo("semana"), campo("spi"), campo("cpi")], True),
        "spec": {
            "version": 3,
            "widgetType": "line",
            "encodings": {
                "x": {"fieldName": "semana", "scale": {"type": "temporal"}, "displayName": "semana"},
                "y": {"scale": {"type": "quantitative"}, "format": INDICE,
                      "fields": [{"fieldName": "spi", "displayName": "SPI"},
                                 {"fieldName": "cpi", "displayName": "CPI"}]},
            },
            "annotations": [linha_de_corte("y", 0.9, "atenção (0,9)")],
            "frame": moldura("SPI e CPI semanais da carteira", "Σ EV ÷ Σ PV e Σ EV ÷ Σ AC por sexta, desde 07/03/2025"),
        },
    }, "position": pos(0, 16, 12, 6)},
    tabela("tabela_projetos", "ds_carteira", [
        ("projeto", "projeto", None),
        ("cliente", "cliente", None),
        ("gerente_projeto", "gerente", None),
        ("situacao", "situação", None),
        ("spi", "SPI", INDICE),
        ("cpi", "CPI", INDICE),
        ("estouro_previsto", "estouro previsto", REAIS),
        ("margem_projetada", "margem projetada", PERCENT),
        ("atraso_projetado_dias", "atraso projetado (dias)", INTEIRO),
        ("farol_do_gerente", "farol do gerente", None),
        ("farol_calculado", "farol pelo número", None),
        ("melancia", "melancia", None),
    ], "Projetos em andamento: o farol do gerente ao lado do farol pelo número", pos(0, 22, 12, 9),
        "Melancias primeiro, depois do menor SPI ao maior"),
]

# ---------------------------------------------------------------------------
# Página 2 · Pessoas (pergunta 3)
# ---------------------------------------------------------------------------
pessoas = [
    texto("titulo_pessoas", [
        "## Tenho gente parada enquanto outro projeto pede gente?\n",
        "\n",
        "Timesheet das últimas 12 semanas (31/07 a 16/10/2026). Hora parada = disponível − apontada; "
        "o custo dela = horas paradas × custo/hora da pessoa. A causa do bloqueio vem do texto do status semanal.",
    ], pos(0, 0, 12, 2)),
    barra_horizontal("barra_pessoas_paradas", "ds_pessoas_top", "pessoa", "custo_ocioso", "papel",
                     "Custo da hora parada por pessoa (top 15)", REAIS, pos(0, 2, 6, 8),
                     mapeamento_cores=[{"value": "sre", "color": CRITICO}]),
    barra_horizontal("barra_causas", "ds_causas", "projeto_id", "status", "causa_bloqueio",
                     "Status bloqueados por projeto e causa (90 dias)", INTEIRO, pos(6, 2, 6, 8),
                     descricao="Os 15 projetos com mais status bloqueados desde 18/07/2026"),
    tabela("tabela_utilizacao", "ds_utilizacao", [
        ("colaborador_id", "colaborador", None),
        ("nome", "nome", None),
        ("papel", "papel", None),
        ("senioridade", "senioridade", None),
        ("projeto_id", "projeto", None),
        ("horas_disponiveis", "horas disponíveis", INTEIRO),
        ("horas_apontadas", "horas apontadas", INTEIRO),
        ("horas_ociosas", "horas paradas", INTEIRO),
        ("utilizacao", "utilização", PERCENT),
        ("custo_ocioso", "custo da hora parada", REAIS),
        ("spi_do_projeto", "SPI do projeto", INDICE),
    ], "Utilização por pessoa e projeto, da mais parada à mais ocupada", pos(0, 10, 12, 9)),
]

# ---------------------------------------------------------------------------
# Página 3 · Fornecedores (pergunta 4)
# ---------------------------------------------------------------------------
fornecedores = [
    texto("titulo_fornecedores", [
        "## O que vai dar errado no próximo mês?\n",
        "\n",
        "As entregas das consultorias: prometido × entregue. A CodeForge vinha escrita de 4 jeitos no "
        "cadastro; normalizada, o atraso dela aparece inteiro.",
    ], pos(0, 0, 12, 2)),
    tabela("tabela_fornecedores", "ds_fornecedores", [
        ("fornecedor", "fornecedor", None),
        ("grafias_no_cadastro", "grafias no cadastro", INTEIRO),
        ("entregas", "entregas", INTEIRO),
        ("prazo_real_sobre_prometido", "prazo real ÷ prometido", INDICE),
        ("pct_no_prazo", "% no prazo", PERCENT),
        ("em_atraso_hoje", "em atraso hoje", INTEIRO),
    ], "Entregas por fornecedor", pos(0, 2, 12, 5),
        "Prazo real ÷ prometido e % no prazo só nas entregas já feitas"),
    tabela("tabela_atrasadas", "ds_atrasadas", [
        ("entrega_id", "entrega", None),
        ("projeto_id", "projeto", None),
        ("fornecedor", "fornecedor", None),
        ("item", "item", None),
        ("valor", "valor", REAIS),
        ("data_pedido", "pedido", None),
        ("data_prometida", "prometida para", None),
        ("dias_em_atraso", "dias em atraso", INTEIRO),
    ], "Entregas em atraso hoje (16/10/2026)", pos(0, 7, 12, 5),
        "Em aberto e com a data prometida já vencida"),
]


def pagina(nome, titulo, layout):
    return {"name": nome, "displayName": titulo, "pageType": "PAGE_TYPE_CANVAS",
            "layoutVersion": "GRID_V1", "layout": layout}


def linhas_sql(sql):
    """queryLines: uma string por linha, cada uma terminando em \\n (o AI/BI concatena sem separador)."""
    return [linha + "\n" for linha in sql.strip().splitlines()]


def montar_dashboard():
    datasets = []
    for nome, d in DATASETS.items():
        ds = {"name": nome, "displayName": d["displayName"], "queryLines": linhas_sql(d["sql"])}
        if "columns" in d:
            ds["columns"] = d["columns"]
        datasets.append(ds)
    return {
        "datasets": datasets,
        "pages": [
            pagina("portfolio", "Portfólio", portfolio),
            pagina("pessoas", "Pessoas", pessoas),
            pagina("fornecedores", "Fornecedores", fornecedores),
        ],
        "uiSettings": {"theme": {
            "canvasBackgroundColor": {"light": "#F5F7FB", "dark": FUNDO_ESCURO},
            "widgetBackgroundColor": {"light": "#FFFFFF", "dark": "#1D1D25"},
            "widgetBorderColor": {"light": "#FFFFFF", "dark": "#1D1D25"},
            "fontColor": {"light": FUNDO_ESCURO, "dark": "#F2F4F8"},
            "selectionColor": {"light": AZUL, "dark": CIANO},
            "visualizationColors": [AZUL, CIANO, ATENCAO, "#8E6CEF", "#2BB673", "#F28C38", "#9AA5B8", CRITICO],
            "widgetHeaderAlignment": "LEFT",
        }},
    }


def com_nome_completo(sql):
    """Para testar fora do dashboard: FROM tabela → FROM lakehouse_vertice.gold.tabela."""
    padrao = r"\b(FROM|JOIN)\s+(" + "|".join(TABELAS_GOLD) + r")\b"
    return re.sub(padrao, r"\1 lakehouse_vertice.gold.\2", sql)


def main():
    sys.stdout.reconfigure(encoding="utf-8")  # o console do Windows usa cp1252
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sql", metavar="PASTA", help="grava as queries com o nome completo, uma .sql por dataset")
    args = p.parse_args()

    if args.sql:
        pasta = Path(args.sql)
        pasta.mkdir(parents=True, exist_ok=True)
        for nome, d in DATASETS.items():
            (pasta / f"{nome}.sql").write_text(com_nome_completo(d["sql"]).strip() + "\n", encoding="utf-8")
        print(f"{len(DATASETS)} queries em {pasta}")
        return

    painel = montar_dashboard()
    # ensure_ascii=False + utf-8: no Windows o padrão é cp1252 e quebraria os acentos
    SAIDA.write_text(json.dumps(painel, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    widgets = sum(len(pg["layout"]) for pg in painel["pages"])
    print(f"{SAIDA.relative_to(RAIZ)}: {len(painel['datasets'])} datasets, "
          f"{len(painel['pages'])} páginas, {widgets} widgets")


if __name__ == "__main__":
    main()
