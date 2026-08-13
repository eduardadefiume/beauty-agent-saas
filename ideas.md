# Direção visual — Painel do Piloto William

## Abordagens consideradas

### 1. Caderno de Operações
Uma interface editorial inspirada em relatórios de campo, hospitality premium e sistemas de sinalização suíços. O painel deve transformar infraestrutura em algo legível, calmo e acionável, sem parecer um painel genérico de métricas.

**Probability:** 0.07

### 2. Oficina Solar
Uma direção mais tátil e humana, baseada em papel, luz de fim de tarde, cerâmica e materiais de salão. O progresso seria apresentado como uma sequência de objetos e rituais de operação.

**Probability:** 0.04

### 3. Linha de Comando
Uma linguagem escura e técnica, com mapas de dependência, logs e indicadores de integridade em tempo real. Mais apropriada para uma central de SRE do que para o acompanhamento de um piloto de beleza.

**Probability:** 0.02

## Abordagem escolhida: Caderno de Operações

### Design Movement
Modernismo editorial suíço reinterpretado com quiet luxury brasileiro: uma composição de grade assimétrica, tipografia de contraste e materiais visuais inspirados em papel de arquivo, madeira clara e sinalização operacional.

### Core Principles
1. **Estado antes de ornamento:** cada componente visual precisa responder rapidamente se algo está configurado, conectado, testado ou pendente.
2. **Precisão com calor:** dados técnicos aparecem com rigor, mas a linguagem visual evita frieza de console.
3. **Assimetria controlada:** a página usa uma coluna de navegação persistente, blocos largos e módulos deslocados para criar ritmo sem perder escaneabilidade.
4. **Evidência visível:** todo status importante mostra o que sustenta a afirmação e separa configuração de teste real.

### Color Philosophy
O fundo é parchment, um quase branco quente que remete a papel de relatório e reduz a dureza de dashboards frios. Ink blue sustenta leitura e confiança. Olive é a cor proprietária do piloto: sinaliza integridade e avanço, sem a linguagem genérica de verde de sucesso. Terracotta aparece apenas como alerta contextual e marca de atenção. O contraste deve parecer impresso, não luminoso.

### Layout Paradigm
Sidebar estreita e persistente à esquerda como índice de um caderno. O conteúdo abre com um cabeçalho de contexto e um bloco de “situação atual” em composição horizontal. Abaixo, uma faixa de marcos atravessa a página como régua temporal; os detalhes são distribuídos em módulos de tamanhos diferentes, evitando uma sequência uniforme de cards centralizados.

### Signature Elements
1. **Régua de progresso:** uma linha vertical/diagonal com pontos numerados para Fase 1, ingestão, IA e agenda.
2. **Marcadores de evidência:** pequenas etiquetas monoespaçadas com “CONFIGURADO”, “VERIFICADO”, “PENDENTE” e “NÃO TESTADO”.
3. **Recortes editoriais:** imagens de salão e textura topográfica entram como recortes em bordas, nunca como decoração dominante.

### Interaction Philosophy
Interações devem esclarecer o próximo passo. Hover revela evidência e origem do status; clicar num módulo expande os detalhes sem levar a uma página sem saída. Ações ainda não implementadas exibem toast explícito de “em breve”, sem fingir que existe atualização em tempo real.

### Animation
Entradas em cascata de 40–60 ms por módulo, usando apenas opacity e translateY, com easing `cubic-bezier(0.23, 1, 0.32, 1)`. Hover dos marcadores usa deslocamento de 2 px e mudança de cor em até 180 ms. A régua de progresso desenha sua linha uma única vez ao carregar. Respeitar `prefers-reduced-motion` e remover movimentos não essenciais.

### Typography System
Display: **DM Serif Display**, usado apenas em títulos de contexto e números heroicos, com itálico pontual para criar voz editorial. Interface e corpo: **Manrope**, em pesos 400–800 para leitura e hierarquia. Dados técnicos e labels: `ui-monospace`, com tracking positivo e caixa alta. Nunca usar Inter.

### Brand Essence
**O painel operacional que transforma a primeira integração de agenda e WhatsApp do William em evidência legível para decisões reais.**

Personalidade: **preciso, sereno, exigente**.

### Brand Voice
Headlines são curtas e situacionais. CTAs descrevem ação observável, não promessa. Microcopy assume o que ainda não foi testado e nunca mascara simulação como produção.

Exemplos:

> “O caminho está configurado. Falta provar a primeira mensagem.”

> “Abrir evidência do webhook”

### Wordmark & Logo
O símbolo é uma abertura geométrica formada por duas lâminas arredondadas que sugerem simultaneamente um W, uma tesoura de salão e um check de calendário. O wordmark deve ser tipográfico, em Manrope ExtraBold com espaçamento amplo e o nome “WILLIAM / PILOTO” em duas linhas, nunca substituindo o símbolo.

### Signature Brand Color
**Olive Signal — `#6E7A4A`**. Um verde-oliva seco, reconhecível e operacional, usado para indicar avanço comprovado e não apenas estado positivo.

### Assets aprovados
- Hero: `/manus-storage/william-pilot-hero_f9077983.jpg`
- Textura: `/manus-storage/william-pilot-texture_e895a12e.jpg`
- Símbolo: `/manus-storage/william-pilot-mark_4c4daad9.png`
- Detalhe: `/manus-storage/william-pilot-detail_c7cd650e.jpg`

**Pergunta de decisão aplicada em todos os arquivos:** esta escolha reforça ou dilui a lógica do Caderno de Operações?

## Style Decisions

- A navegação principal do Painel William é sempre um índice lateral estreito em estilo caderno operacional; a navegação superior fica restrita a contexto e ações secundárias.
- O símbolo aprovado e o wordmark “WILLIAM / PILOTO” aparecem no primeiro plano do hero e funcionam como assinatura recorrente do sistema.
- Todo bloco editorial carrega um vínculo visível com evidência operacional: status, origem, fase, pendência ou próxima prova.
- O hero mostra explicitamente a separação entre configuração validada e prova pendente, evitando que a imagem de salão transforme o painel numa peça institucional.
