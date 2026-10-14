# Aleatoriedade suave

Um rand puro é granulado demais para matéria: papel, tinta e terreno pedem ruído que varia devagar — aleatoriedade suave. A escada é sempre a mesma: um hash determinístico, interpolação entre valores hashados, e oitavas empilhadas. O módulo `noise.slang` já entrega a escada completa; aqui você entende cada degrau para escrever as variações (gradient noise, simplex) por conta própria.

## 1. O hash: aleatoriedade sem estado

hash21 mapeia um float2 num [0, 1) determinístico: mesma entrada, sempre a mesma saída, sem guardar nada. O sin com constantes grandes espalha os bits; o frac recolhe para [0,1).

```
hash21(p) = frac(sin(dot(p, (127.1, 311.7))) * 43758.5453123)
```

Não é criptografia nem estatística — é suficiente visualmente e barato. O que importa: é uma função pura, chamável de qualquer pixel independente, que é o contrato do compute.

[Abrir a cena 06_noise](scene:06_noise): troque o corpo do `hash21` local por qualquer constante quebra-o: `return 0.5;` — e veja a tela virar cinza chapado.

## 2. Value noise: hash os cantos, interpole dentro

Value noise consulta o hash nos 4 cantos da célula que contém o ponto e interpola dentro com a curva de smoothstep (`u = f*f*(3-2f)`), que zera a derivada nas bordas — é isso que tira os vincos do ruído linear.

```
valueNoise(p):
    i = floor(p);  f = p - i
    u = f * f * (3.0 - 2.0 * f)
    a = hash21(i + (0,0));  b = hash21(i + (1,0))
    c = hash21(i + (0,1));  d = hash21(i + (1,1))
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y)
```

Sem a curva u (lerp direto em f), o resultado mostra diagonais visíveis: a grade vazia. É o teste que separa ruído de tabela.

[Abrir a cena 06_noise](scene:06_noise): no `valueNoise` local, troque `u = f*f*(3-2f)` por `u = f` e procure as diagonais que aparecem.

## 3. FBM: oitavas com lacunarity e gain

Um oitava de ruído é blob. Matéria real tem detalhe em todas as escalas: some oitavas, cada uma com frequência multiplicada por `lacunarity` e amplitude multiplicada por `gain`:

```
sum = 0.0; amp = 0.5; freq = 1.0
for i in 0..octaves:
    sum += amp * noise(p * freq)
    freq *= lacunarity;   // 2.0: cada oitava metade do tamanho
    amp  *= gain;         // 0.5: cada oitava metade da força
```

A soma de uma oitava de referência amplitudes 0.5 + 0.25 + 0.125 + ... converge para 1.0 — por isso o resultado cabe em [0, 1) e lida bem com lerp. O `Noise::fbm(p, octaves, lacunarity, gain)` de `noise.slang` é exatamente esse laço, com um offset fixo entre oitavas para quebrar o alinhamento da grade.

[Abrir a cena 06_noise](scene:06_noise): o painel Controls expõe frequency e octaves — suba octaves para 8 e baixe para 1 e observe o de-para com o laço acima.

## 4. Onde o ruído mora no projeto

As primitivas (`Noise::hash21`, `Noise::valueNoise`, `Noise::fbm` de 4 argumentos) vivem em `noise.slang`; uma cena importa com `import "../../noise";` e chama pelo namespace: `Noise::fbm(...)`. Cenas que precisam de assinaturas diferentes (a 06 usa fbm de 2 argumentos) declaram as suas próprias localmente — o conflito de nomes é evitado por escopo de módulo, e as trilhas seguintes pedem que você estenda o módulo com as variantes.

Gradient noise fica de fora de propósito: em vez de valores nos cantos, os cantos guardam vetores e o produto interno com o offset dá o ruído — sem vincos direcionais e com derivadas melhores. Implemente o seu em `noise.slang` (dentro de `namespace Noise`) quando o value noise exibir grade nos zooms grandes.

## Próximo passo

Você tem forma (SDF), trajetória (raio) e matéria (ruído). Volte à [Distância como forma](trail:sdf-basics) e preencha o `sdf.slang` com os primitivos que faltam — as cenas vão puxá-los assim que existirem.
