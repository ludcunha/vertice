# CLAUDE.md

Material e código da **Imersão Databricks + Claude Code** (Jornada de Dados, 19 a 22/10/2026): construir
ao vivo, em 4 noites de 1h30, o **Projeto Farol**, a Torre de Controle de Projetos da **Vértice Tecnologia** (empresa
de tecnologia fictícia, 520 pessoas, 60 projetos de clientes). A narrativa: você é o único profissional de dados da
Vértice, então faz o trabalho de analista, engenheiro, cientista e engenheiro de IA; o dono faz 4 perguntas (quais projetos atrasam e de quais clientes; quanto custa; tenho gente parada enquanto
outro pede gente; o que vai dar errado no próximo mês). O problema central: os projetos vivem em **Excel (20), ClickUp
(25) e MS Project (15)**, sem centralização. Noite 1 mostra o Databricks inteiro e junta à mão; noite 2 é a integração.

> O case anterior (outra empresa fictícia) está na tag `atlas-out26`; o catálogo `lakehouse_atlas` e os recursos
> dele no workspace ficaram intocados. Nada no main depende deles.

Todo o conteúdo é em português e escrito para ser acompanhado ao vivo por um público misto: cerca de metade
nunca programou ou só fez exercícios.

## Organização

Uma pasta por noite, autocontida (README, roteiro, verificação), no mesmo esquema do repositório de agosto
(`lvgalvao/projeto-dados-ia-databricks`):

| Pasta | Noite |
|---|---|
| `aulas/aula-01-analista-sql/` | 1 · navegador: setup, bronze (CSV, Excel, JSON, XML), 6 exemplos SQL, dashboard sobre a bronze, Genie sem curadoria |
| `aulas/aula-02-python-engenheiro/` | 2 · notebooks: aquecimento de Python, data lake (Supabase Storage via S3/boto3) → raw → bronze, API de feriados, job de ingestão. Na pasta: README (com todo o código), aquecimento + gabarito e os notebooks 01_ingestao_api e 02_ingestao_boto3 |
| `aulas/aula-03-modelagem-claude-code/` | 3 · 5 prompts no Claude Code: o job de ingestão da noite 2 vira código (`bundle generate`, chaves em variável fora do Git) + conferência, silver (as 3 ferramentas viram uma), gold + testes, job completo + IA no texto do status, dashboard. Em `claude-code/`: o passo a passo, os prompts (`prd/`) e o gabarito do bundle (`vertice/`, estado final da semana) |
| `aulas/aula-04-produtos-de-dados-ia/` | 4 · 2 prompts (desde 22/10): o app da Torre (AppKit) e depois o agente de IA (metric view + Genie curado), plugado no app; o ML é demonstrado ao vivo; pitch e mercado de trabalho. Em `bonus/`: o prompt do ML, a aprovação no Lakebase e o agente de contratos |
| `material/` | PRD, gerador do dataset, validador dos padrões, writer de PDF |
| `scripts/` | `run_sql.py`, `genie.py`, `gerar_notebooks.py`, `gerar_slides.py`, `gerar_prompts.py` |
| `slides/` | `_modelo.html` (motor dos slides do jornada-ops, com Mermaid) + `imersao.slides.html` → `imersao.html` (um deck só, as 4 noites) e `pptx/` (versão editável) |

Exemplos novos na aula 01 seguem `exemplo-NN-tema.sql`, com cabeçalho de conceito, pergunta de negócio e
conexão com a noite seguinte. Depois de editar um exemplo, rode `python3 scripts/gerar_notebooks.py aulas/aula-01-analista-sql`.

## Databricks

- Carregue a skill `databricks-core` antes de qualquer ação, mais a do produto (`databricks-dabs`,
  `databricks-pipelines`, `databricks-metric-views`, `databricks-genie-agents`, `databricks-apps`…).
- **Nunca escolha um profile sozinho.** O profile de desenvolvimento desta imersão é `imersao-out26`
  (workspace `dbc-84cd5511-fa25`, o mesmo de agosto, que também tem `lakehouse_rotaperfume`).
- Ambiente-alvo: **Free Edition, serverless**. Warehouse `Serverless Starter Warehouse` (`666be37e3fededf2`).
- Catálogo **`lakehouse_vertice`**. `CREATE CATALOG` só via SQL:
  a API do UC recusa no Free Edition.
- Skills oficiais do Databricks instaladas no projeto (`.claude/skills/`, 32 com as experimentais) via
  `databricks aitools install --agents claude-code --scope project --skills-only --experimental`.
- ✅ `read_files` lê Excel (`format => 'excel'`, `headerRows => 1`), XML (`rowTag => 'Task'`) e JSON (`multiLine`).
  No Excel use `inferColumnTypes => false` (tudo texto; `_metadata.file_name` vem codificado: `url_decode`). No XML e no
  JSON **deixe inferir**: com `false` as estruturas aninhadas viram texto.
- Volume não aceita escrita fora de ordem: o `.xlsx` é montado em memória (`material/xlsx_simples.py`).

### O que funciona no Free Edition (medido em 18/10/2026)

- ✅ Lakebase (`databricks postgres create-project`). Em agosto não existia.
- ✅ `ai_extract`, `ai_classify`, `ai_query`; AI/BI; Genie Agents (com modo Agent); Apps.
- ✅ Notebook serverless tem internet e lê arquivo do Git folder (`os.getcwd()` é a pasta do notebook).
- ✅ Metric Views, **mas só pela API de statements**. `databricks experimental aitools tools query` achata a
  indentação e o YAML quebra com `Missing required creator property 'expr'`. Por isso o `scripts/run_sql.py`
  usa `databricks api post /api/2.0/sql/statements`.
- ❌ Knowledge Assistant e Supervisor Agent: "legacy feature, use Genie Agents instead". Não criam mais.
- ❌ Endpoint de modelo próprio: só Foundation Models. Score de ML em lote, gravado na gold.
- Herdado de agosto (ML): `spark_udf` não roda no serverless; XGBoost não carrega de volta (use
  `HistGradientBoostingClassifier`); `mlflow.set_experiment` não cria a pasta pai; serverless traz MLflow 2.x
  (`artifact_path=`); DECIMAL precisa de `.cast("double")` antes de registrar o modelo.
- Herdado de agosto (Apps): `bundle deploy` cria o app parado, o deploy é `databricks apps deploy`; o service
  principal do app precisa de `GRANT USE CATALOG/USE SCHEMA/SELECT`; o warehouse devolve número como string.
- URL de dashboard publicado: `https://<host>/dashboardsv3/<id>/published` (sem `/sql`).

- ⚠️ Registro de modelo no UC falha com o MLflow 2.11 do serverless (`s3:PutObject explicit deny`):
  `%pip install -U "mlflow-skinny[databricks]>=2.21,<3"` + `dbutils.library.restartPython()`.
- Apagar o pipeline não apaga as materialized views: o `00-reset.sh` da noite 2 apaga uma a uma.
- O Genie do bundle exige as tabelas: do zero, a ordem é deploy → run → deploy.
- Editar dashboard ou Genie direto no workspace trava o `bundle deploy` ("modified remotely"):
  leve a mudança para o JSON do repositório e use `--force` só depois disso.
- Lakebase: apagar projeto é exclusão suave por 7 dias e prende o nome (use `delete-project --purge` no reset;
  confira com `list-projects`, não com `get-project`). O build do app roda o typegen **como o service principal**:
  os GRANTs vêm antes do segundo `apps deploy`. Nenhum arquivo `*.geniespace.json` dentro da pasta do app.
- Free Edition: no máximo **3 apps** por workspace (`maximum limit of 3 apps`). Libere um antes do `bundle deploy` do app.
- A `sql_task` do job corta o arquivo em todo `;`, inclusive dentro do `$$ ... $$` da metric view: nada de `;` no YAML.
- Testar o app local (`npm run dev`) cria o schema `torre` no Lakebase com você como dono: apague antes do deploy.
- O primeiro acesso ao app pede consentimento OAuth ("Authorize"), feito por uma pessoa. Testes automáticos
  usam `Authorization: Bearer $(databricks auth token)`.
- Nomes de Genie e dashboard são únicos por título nos scripts: "Farol · Noite 1 (bronze, sem curadoria)", dashboard
  "Projeto Farol · Noite 1 (bronze)", "Farol · Diretoria" (noite 2, do bundle) e "Farol · Diretoria + Contratos" (noite 4).
- `ai_classify`/`ai_extract` na versão 2.0 (`map('version','2.0')`) devolvem VARIANT: `:response[0]::STRING` e
  `:response:campo::DOUBLE`. Com JSON schema tipado o `ai_extract` devolve número ("1 semana" → 7).
- Bundle renomeado ou copiado: apague a `.databricks/` local antes do primeiro deploy (senão edita os recursos antigos).
- Slides com Mermaid: `<div class="diagrama"><pre class="mermaid">…</pre></div>`; o motor desenha antes de esconder os
  slides e sem a escala do palco (senão o Mermaid mede o texto encolhido e corta os rótulos).

Aprendizados detalhados de cada noite: `aulas/<noite>/APRENDIZADOS.md` (na noite 3, `claude-code/APRENDIZADOS.md`; o do ML está no da noite 4).

## Dataset

`python3 material/gerar_dataset.py --saida ./dados --seed 42` (só stdlib, < 1 s, 7 MB) e
`python3 material/validar_padroes.py --dados ./dados` (sai com 1 se um padrão sumir; é o gabarito da centralização:
lê as 3 ferramentas em Python). Um `random.Random` por assunto (`f"{seed}:{nome}"`): mexer num bloco não muda os outros.

- **"Hoje" = 2026-10-16.** Nunca `current_date()`.
- **A sujeira é conteúdo, não bug.** Nunca conserte o gerador para limpar dado. A limpeza é na silver (noite 2).
- **Seed fixa.** Mudou o gerador? Rode o validador, regere, recarregue a bronze e atualize os números esperados
  em `aulas/aula-01-analista-sql/99-verificacao.sql`, nos READMEs e nos slides, nessa ordem.
- Fontes: `pmo/` (projetos, status_semanal com texto livre e farol), `excel/` (20 .xlsx), `clickup/` (25 .json),
  `msproject/` (15 .xml MSPDI), `rh/`, `timesheet/`, `financeiro/`, `compras/` (entregas de fornecedor), `documentos/`
  (8 contratos de fornecedor/SaaS e o manual de tecnologias em PDF; o agente da noite 4 lê só os contratos).
- **Caso enxuto (19/10):** 9 tabelas na bronze, 7 na silver (+2 dos contratos), 7 objetos na gold (projeto_situacao_atual,
  fato_projeto_semana, utilizacao_pessoa_semana, status_estruturado, mv_projetos, score_estouro_30d, contratos) e o schema
  `ml` (features, métricas e o modelo). Saíram alocações, capacidade/cloud e postmortems: história paralela às 4 perguntas.
  As alocações ainda são calculadas por dentro do gerador (o timesheet depende delas), mas não viram arquivo.
- Padrões que os KPIs precisam mostrar: CPI caindo a partir do 6º mês em `PRJ-002 005 009 014 018 021 027 033`
  (escopo sem aditivo); change freeze da Black Friday (01/11 a 10/01) em `PRJ-003 011 024` (e-commerce);
  consultoria CodeForge com prazo ×1,41 e escrita de 4 jeitos; SREs `COL0017`/`COL0018` a 2–9% no `PRJ-007`
  (ainda no discovery) enquanto o `PRJ-011` pede SRE nos status; squads com rotatividade em `PRJ-016 030`.
  Bônus: 4 projetos "melancia" (farol verde, SPI < 0,9): `PRJ-012 028 034 042`.

## Números de referência

Noite 3 (gold, replanejada em 21/10; era a noite 2): os mesmos 7 críticos, 10 em atenção, 4 melancias e R$ 6,47 mi da noite 1 (a fotografia de hoje faz a
mesma conta sobre silver.tarefas) · SPI/CPI da carteira 0,92/0,97 · margem projetada 20,4% · 4.917 tarefas na silver
(Excel 1.643, ClickUp 2.119, Project 1.155) · 5 entregas em atraso, todas
da CodeForge (×1,41, 0% no prazo) · SREs COL0017/COL0018 a ~5,5% no PRJ-007 · PRJ-011: falta_sre 12 semanas, 57 dias ·
IA: 163 status (2 min) · Genie "Farol · Diretoria" 20/20 · verificação 20/20. Pergunta 4 na noite 3: entregas atrasadas +
freeze; a resposta completa é o score da noite 4. (Genie e metric view saíram da noite 3 para a 4.)

Noite 4 (schema `ml`; era a noite 3): ml.features_projeto_semana 4.235 linhas · AUC 0,92 (regra atual 0,50; folga 0,87) · 9 de 10 estouros do teste no
top 5, 41 dias antes · score: 18 alto, 4 médio, 19 baixo · "uau": PRJ-024 ok hoje (SPI 0,91) com prob 0,46 e o freeze da
Black Friday começando em 01/11 · vazamento: corte no tempo 0,92, aleatório 0,92, índice do futuro 0,99 · assert antivazamento < 0,98 ·
job vertice_farol com 10 tarefas: 9 min 55 s, todas verdes, verificação 20/20 (ensaio de 21/10; só a parte da noite 3 leva ~8 min). PRJ-013 tem status (43%) e planilha (45%) que não batem: lição de qualidade.
Bônus (agente de contratos, fora do ao vivo desde 21/10): 8 contratos, 72 cláusulas (silver), gold.contratos com 8 linhas · multa cobrável da CodeForge R$ 1,12 mi (vigência atual) ·
NuvemSul e DataPrime renovaram sozinhos (R$ 21,4 mi/ano) · Genie "Farol · Diretoria + Contratos" 10/10.
Noite 4 (app): simulador
COL0017 → PRJ-011: 19 dias e R$ 22,1 mil/mês de saldo · ROI ≈ R$ 3,0 mi no ano 1 contra R$ 0,4 mi · app `farol-torre`
publicado em 18/10 (bundle deploy falha no 1º build → conceder-acesso.sh → apps deploy: RUNNING).

### Noite 1 (Vértice)

60 projetos (41 em andamento) · carteira R$ 305,2 mi (R$ 208,6 mi em andamento) · custo real R$ 193,35 mi
(R$ 187,94 mi com `try_cast`: 671 lançamentos perdidos) · 17 projetos em risco, 7 críticos · estouro previsto
R$ 6,47 mi · piores SPI PRJ-016 0,63, PRJ-030 0,69, PRJ-039 0,75, PRJ-011 0,77 · 32 faróis verdes, 4 melancias.
Genie sem curadoria erra as 4 perguntas do dono (ensaio 18/10).

## Comandos

```bash
python3 scripts/run_sql.py <arquivo.sql> --profile imersao-out26 [--continuar] [--quiet]
python3 aulas/aula-01-analista-sql/gerar_dashboard.py --deploy --profile imersao-out26
python3 scripts/genie.py publicar <espaco.json> --titulo "..." --profile imersao-out26
python3 scripts/genie.py perguntar "<título>" "pergunta" --profile imersao-out26
python3 scripts/genie.py benchmark "<título>" <benchmark.json> --profile imersao-out26
python3 scripts/gerar_notebooks.py aulas/aula-01-analista-sql [--importar --profile imersao-out26]
python3 scripts/gerar_slides.py slides/imersao.slides.html
python3 scripts/gerar_prompts.py                 # regera o PROMPTS.md a partir de aulas/*/prd/prompt-*.md
```

## Slides

Visual da Jornada (Poppins, `#14141A`, azul `#0059DB`, ciano `#22C2F4`), o mesmo motor das apresentações do time
(`jornada-ops/scripts/apresentacao_time.py`). Escreva só as `<section class="slide">` em `slides/imersao.slides.html`
e rode o `gerar_slides.py`. `[[IMG:docs/img/x.jpg]]` embute o print; `[[RODAPE]]` põe logo e número da página.
Todo número do slide sai de uma query rodada; cite a fonte no README da noite.

## Convenções

- Código e comentários para quem assiste ao vivo pela primeira vez: SQL legível, não esperto.
- Tabelas e colunas em snake_case e português. Referência completa `lakehouse_vertice.<schema>.<tabela>` nos `.sql`;
  nome sem catálogo **dentro** do JSON do dashboard (catálogo e schema entram no deploy).
- Sempre `--profile`. Nada de `mode: development` no bundle (prefixa os schemas). Use `presets.trigger_pause_status`.
- Responda em português, curto e direto.
