-- gold.projeto_situacao_atual e gold.utilizacao_pessoa_semana.
--
-- Por quê:
--   projeto_situacao_atual é a fotografia de hoje (16/10/2026) e responde às
--   perguntas 1 e 2 do dono: quem está atrasado, de qual cliente, e quanto isso
--   vai custar (EAC, estouro, margem). Os KPIs saem das TAREFAS das três
--   ferramentas (o % de hoje de cada tarefa), não do % que o gerente declarou.
--   Por isso dá para achar a "melancia": verde por fora (farol do gerente),
--   vermelha por dentro (SPI < 0,9).
--   Ela já traz o cadastro do projeto: não existe dim_projeto.
--
--   utilizacao_pessoa_semana responde à pergunta 3 ("tenho gente parada enquanto
--   outro projeto pede gente?"): horas ociosas e o custo delas, ao lado do SPI do
--   projeto naquela semana.
--
-- Regras de corte: SPI ou CPI < 0,9 = atenção · < 0,8 = crítico.
-- Farol calculado (manual da Vértice): verde com SPI >= 0,95 · amarelo >= 0,90 · vermelho abaixo.
-- "Hoje" é DATE'2026-10-16'. Nunca current_date().

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.projeto_situacao_atual
COMMENT 'Fotografia de 16/10/2026 de cada um dos 60 projetos (uma linha por projeto_id): cadastro (cliente, segmento, tipo, ferramenta, gerente, contrato, orçamento, datas e duração do baseline, status) e os KPIs calculados sobre as tarefas das três ferramentas. pv, ev e ac em R$, spi = ev/pv (< 1 atraso), cpi = ev/ac (< 1 estouro), eac = orcamento/cpi, estouro_previsto = eac - orcamento quando positivo, margem_projetada = (contrato - eac)/contrato, atraso_projetado_dias e termino_projetado pelo SPI. situacao: concluído, crítico (SPI ou CPI < 0,8), atenção (< 0,9) ou ok. farol_do_gerente é o do último status publicado, farol_calculado segue o manual (verde >= 0,95, amarelo >= 0,90). melancia = em andamento, farol do gerente verde e SPI < 0,9.'
AS
WITH kpi_tarefas AS (
  SELECT
    projeto_id,
    sum(horas)                       AS horas_totais,
    sum(horas * pct_concluido / 100) AS horas_agregadas,
    sum(horas * CASE
          WHEN fim_baseline <= inicio_baseline THEN IF(DATE'2026-10-16' >= fim_baseline, 1, 0)
          ELSE greatest(0, least(1, datediff(DATE'2026-10-16', inicio_baseline)
                                    / datediff(fim_baseline, inicio_baseline)))
        END)                         AS horas_planejadas
  FROM tarefas
  GROUP BY projeto_id
),

custo_hoje AS (
  SELECT projeto_id, sum(valor) AS ac
  FROM custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id
),

ultimo_status AS (
  SELECT projeto_id, max_by(farol, data_status) AS farol_do_gerente
  FROM status_semanal
  WHERE data_status <= DATE'2026-10-16'
  GROUP BY projeto_id
),

base AS (
  SELECT
    p.projeto_id,
    concat(p.projeto_id, ' · ', p.nome_projeto)                        AS projeto,
    p.nome_projeto,
    p.cliente,
    p.segmento,
    p.tipo_projeto,
    p.ferramenta,
    p.gerente_projeto,
    p.valor_contrato,
    p.orcamento_custo                                                  AS orcamento,
    p.data_inicio,
    p.data_fim_baseline,
    datediff(p.data_fim_baseline, p.data_inicio)                       AS duracao_baseline_dias,
    p.status,
    round(p.orcamento_custo * try_divide(k.horas_planejadas, k.horas_totais), 2) AS pv,
    round(p.orcamento_custo * try_divide(k.horas_agregadas,  k.horas_totais), 2) AS ev,
    CAST(coalesce(c.ac, 0) AS DECIMAL(18, 2))                          AS ac,
    u.farol_do_gerente
  FROM projetos p
  LEFT JOIN kpi_tarefas   k ON k.projeto_id = p.projeto_id
  LEFT JOIN custo_hoje    c ON c.projeto_id = p.projeto_id
  LEFT JOIN ultimo_status u ON u.projeto_id = p.projeto_id
),

com_indices AS (
  SELECT
    *,
    round(try_divide(ev, pv), 4) AS spi,
    round(try_divide(ev, ac), 4) AS cpi
  FROM base
),

com_eac AS (
  SELECT
    *,
    round(try_divide(orcamento, cpi), 2) AS eac
  FROM com_indices
)

SELECT
  projeto_id,
  projeto,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  ferramenta,
  gerente_projeto,
  valor_contrato,
  orcamento,
  data_inicio,
  data_fim_baseline,
  duracao_baseline_dias,
  status,
  pv,
  ev,
  ac,
  spi,
  cpi,
  eac,
  greatest(eac - orcamento, 0)                                         AS estouro_previsto,
  round(try_divide(valor_contrato - eac, valor_contrato), 4)           AS margem_projetada,
  CAST(round(try_divide(duracao_baseline_dias, spi) - duracao_baseline_dias) AS INT) AS atraso_projetado_dias,
  date_add(data_inicio, CAST(round(try_divide(duracao_baseline_dias, spi)) AS INT))  AS termino_projetado,
  CASE
    WHEN status <> 'em_andamento'   THEN 'concluído'
    WHEN spi < 0.8 OR cpi < 0.8     THEN 'crítico'
    WHEN spi < 0.9 OR cpi < 0.9     THEN 'atenção'
    ELSE 'ok'
  END                                                                  AS situacao,
  farol_do_gerente,
  CASE
    WHEN spi >= 0.95 THEN 'verde'
    WHEN spi >= 0.90 THEN 'amarelo'
    WHEN spi IS NOT NULL THEN 'vermelho'
  END                                                                  AS farol_calculado,
  coalesce(status = 'em_andamento' AND farol_do_gerente = 'verde' AND spi < 0.9, false) AS melancia
FROM com_eac;

-- ---------------------------------------------------------------------------
-- utilizacao_pessoa_semana: pessoa × projeto × semana (sexta)
--   horas_ociosas = disponíveis - apontadas (nunca negativo: hora extra não é ociosidade)
--   custo_ocioso  = horas ociosas × custo/hora da pessoa
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.utilizacao_pessoa_semana
COMMENT 'Utilização do timesheet por pessoa, projeto e semana (sexta-feira): nome, papel e senioridade do colaborador, horas disponíveis, apontadas e ociosas, utilizacao = apontadas/disponíveis (0 a 1), custo_ocioso = horas ociosas × custo/hora (R$) e o spi_do_projeto naquela semana (de fato_projeto_semana), para cruzar gente parada com projeto atrasado.'
AS
SELECT
  a.colaborador_id,
  c.nome,
  c.papel,
  c.senioridade,
  a.projeto_id,
  a.semana_inicio,
  a.semana,
  a.horas_disponiveis,
  a.horas_apontadas,
  greatest(a.horas_disponiveis - a.horas_apontadas, 0)                          AS horas_ociosas,
  round(try_divide(a.horas_apontadas, a.horas_disponiveis), 4)                  AS utilizacao,
  round(greatest(a.horas_disponiveis - a.horas_apontadas, 0) * c.custo_hora, 2) AS custo_ocioso,
  f.spi                                                                         AS spi_do_projeto
FROM apontamentos a
LEFT JOIN colaboradores c
  ON c.colaborador_id = a.colaborador_id
LEFT JOIN lakehouse_vertice.gold.fato_projeto_semana f
  ON f.projeto_id = a.projeto_id
 AND f.semana     = a.semana;
