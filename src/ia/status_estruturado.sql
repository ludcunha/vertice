-- gold.status_estruturado: o texto livre do status semanal vira coluna (sql_task, depois do medalhão).
--
-- Por quê: a causa do atraso (falta de SRE, change freeze, consultoria atrasada...)
-- só existe no texto que o gerente escreve toda sexta. Para responder "tenho gente
-- parada enquanto outro projeto pede gente?" a causa precisa virar coluna.
--
-- Três métodos, do mais barato ao mais caro:
--   regra         status vazio ou "sem bloqueio": não precisa de IA nenhuma
--   ia            últimos 90 dias (desde 18/07/2026) com bloqueio: ai_classify + ai_extract
--                 (~5 s por texto, então só ~160 textos passam pela IA)
--   palavra_chave o histórico mais antigo: RLIKE no trecho de bloqueios
--
-- A tabela ACUMULA: CREATE TABLE IF NOT EXISTS + MERGE só com os status novos.
-- Nunca CREATE OR REPLACE: refazer a IA toda segunda custaria tempo e dinheiro
-- e poderia mudar uma classificação que alguém já usou.
--
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula, então só os fins de
-- comando o usam. "Hoje" é DATE'2026-10-16'.

CREATE TABLE IF NOT EXISTS lakehouse_vertice.gold.status_estruturado (
  projeto_id       STRING    COMMENT 'Projeto do status (PRJ-xxx).',
  data_status      DATE      COMMENT 'Sexta-feira do status semanal.',
  farol            STRING    COMMENT 'Farol declarado pelo gerente: verde, amarelo ou vermelho.',
  causa_bloqueio   STRING    COMMENT 'Causa do bloqueio: change_freeze, falta_sre, dependencia_fornecedor, rotatividade, mudanca_escopo, bug_retrabalho, aprovacao_cliente, sem_bloqueio, nao_reportado (status vazio) ou outro (palavra-chave sem casamento).',
  bloqueio         STRING    COMMENT 'O bloqueio em uma frase. Na IA, extraído pelo ai_extract. Fora dela, o trecho depois de "Bloqueios:" no texto.',
  quem_destrava    STRING    COMMENT 'Quem precisa agir para destravar (cliente, fornecedor, time de infraestrutura...). Só preenchido pela IA.',
  dias_impacto     DOUBLE    COMMENT 'Dias de impacto no prazo declarados no status (1 semana = 7). NULL quando o texto não declara impacto.',
  metodo           STRING    COMMENT 'Como a linha foi classificada: regra (vazio ou sem bloqueio), ia (últimos 90 dias, ai_classify + ai_extract) ou palavra_chave (histórico, RLIKE).',
  texto_status     STRING    COMMENT 'Texto livre original do status semanal.',
  _classificado_em TIMESTAMP COMMENT 'Quando a linha entrou na tabela. Linhas antigas não são reclassificadas.'
)
COMMENT 'Status semanal estruturado: a causa do bloqueio, quem destrava e os dias de impacto tirados do texto livre do gerente. Uma linha por projeto e sexta. Acumula: cada execução só classifica os status novos.';

MERGE INTO lakehouse_vertice.gold.status_estruturado AS alvo
USING (
  WITH novos AS (
    -- só os status que ainda não estão na tabela
    SELECT s.projeto_id, s.data_status, s.farol, s.texto_status, s.status_vazio,
           lower(s.texto_status) AS texto,
           -- o trecho depois de "Bloqueios:" (as entregas da semana não entram na palavra-chave)
           nullif(trim(regexp_extract(s.texto_status, '(?i)bloqueios:\\s*(.*)$', 1)), '') AS trecho_bloqueio
    FROM lakehouse_vertice.silver.status_semanal s
    LEFT ANTI JOIN lakehouse_vertice.gold.status_estruturado e
      ON e.projeto_id = s.projeto_id AND e.data_status = s.data_status
  ),
  com_metodo AS (
    SELECT *,
      CASE
        WHEN status_vazio
          OR texto LIKE '%bloqueios: nenhum%'
          OR texto LIKE '%sem bloqueios%'
          OR texto LIKE '%nada relevante%'      THEN 'regra'
        WHEN data_status >= DATE'2026-07-18'    THEN 'ia'
        ELSE 'palavra_chave'
      END AS metodo
    FROM novos
  ),
  -- a IA roda só aqui, nas linhas com metodo = 'ia'
  ia AS (
    SELECT projeto_id, data_status,
      ai_classify(texto_status,
        '["change_freeze","falta_sre","dependencia_fornecedor","rotatividade","mudanca_escopo","bug_retrabalho","aprovacao_cliente","sem_bloqueio"]',
        map('version', '2.0')):response[0]::STRING AS causa,
      ai_extract(texto_status,
        '{"bloqueio":{"type":"string","description":"o bloqueio do projeto em uma frase"},"quem_destrava":{"type":"string","description":"quem precisa agir para destravar: cliente, fornecedor, time de infraestrutura, gerente etc"},"dias_impacto":{"type":"number","description":"dias de impacto no prazo declarados no texto. 1 semana = 7. Sem impacto declarado = null"}}',
        map('version', '2.0')):response AS extraido
    FROM com_metodo
    WHERE metodo = 'ia'
  )
  SELECT
    c.projeto_id,
    c.data_status,
    c.farol,
    CASE
      WHEN c.status_vazio            THEN 'nao_reportado'
      WHEN c.metodo = 'regra'        THEN 'sem_bloqueio'
      WHEN c.metodo = 'ia'           THEN i.causa
      WHEN lower(c.trecho_bloqueio) RLIKE 'freeze|congelamento|janela de deploy'               THEN 'change_freeze'
      WHEN lower(c.trecho_bloqueio) RLIKE 'sre|infraestrutura|ambiente de homologação'         THEN 'falta_sre'
      WHEN lower(c.trecho_bloqueio) RLIKE 'forge|consultoria|fornecedor'                       THEN 'dependencia_fornecedor'
      WHEN lower(c.trecho_bloqueio) RLIKE 'saída de|rotatividade|onboarding'                   THEN 'rotatividade'
      WHEN lower(c.trecho_bloqueio) RLIKE 'escopo|change request|regra de negócio'             THEN 'mudanca_escopo'
      WHEN lower(c.trecho_bloqueio) RLIKE 'bugs|regressão|refazendo'                           THEN 'bug_retrabalho'
      WHEN lower(c.trecho_bloqueio) RLIKE 'aprovação do cliente|homologação do cliente'        THEN 'aprovacao_cliente'
      ELSE 'outro'
    END AS causa_bloqueio,
    CASE
      WHEN c.metodo = 'ia'    THEN i.extraido:bloqueio::STRING
      WHEN c.metodo = 'regra' THEN NULL
      ELSE c.trecho_bloqueio
    END AS bloqueio,
    CASE WHEN c.metodo = 'ia' THEN i.extraido:quem_destrava::STRING END AS quem_destrava,
    CASE
      WHEN c.metodo = 'ia' THEN i.extraido:dias_impacto::DOUBLE
      WHEN c.texto RLIKE 'impacto estimado de [0-9]+ dias'
        THEN CAST(regexp_extract(c.texto, 'impacto estimado de ([0-9]+) dias', 1) AS DOUBLE)
      WHEN c.texto LIKE '%impacto estimado: 1 semana%' THEN 7.0
    END AS dias_impacto,
    c.metodo,
    c.texto_status,
    current_timestamp() AS _classificado_em
  FROM com_metodo c
  LEFT JOIN ia i
    ON i.projeto_id = c.projeto_id AND i.data_status = c.data_status
) AS novo
ON alvo.projeto_id = novo.projeto_id AND alvo.data_status = novo.data_status
WHEN NOT MATCHED THEN INSERT *;

-- Leitura: quantos status por método e causa
SELECT metodo, causa_bloqueio, count(*) AS status, round(sum(dias_impacto), 0) AS dias_impacto
FROM lakehouse_vertice.gold.status_estruturado
GROUP BY metodo, causa_bloqueio
ORDER BY metodo, status DESC;
