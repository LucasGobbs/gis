# Distância como forma

Um SDF (signed distance field) é uma função que recebe um ponto e devolve a distância dele até a superfície mais próxima: negativa dentro, positiva fora. A forma não é desenhada — ela é o conjunto de pontos onde a distância vale zero. Nesta trilha você aprende a ler e escrever SDFs em 2D, a combiná-los e a transformá-los em máscaras suaves.

## 1. O círculo: a distância mais simples

A distância de um ponto ao centro menos o raio já é um SDF completo. O sinal separa dentro de fora; a magnitude diz quão longe da borda o pixel está.

```
d(p) = length(p) - r
```

Isso vale para qualquer `p` do plano: o campo é contínuo em toda parte, e é essa continuidade que permite anti-aliasing, contornos grossos e animação de raio sem custo extra.

[Abrir a cena 04_shapes](scene:04_shapes): troque `Params.radius` por uma expressão com `Uniforms.iTime` (por exemplo `0.2 + 0.1 * sin(t)`) e veja o círculo respirar.

## 2. A caixa: distância até um retângulo

Para uma caixa alinhada aos eixos, a distância usa o vetor `q = abs(p) - b` (b = meio-lado). Pseudocódigo:

```
sdBox2(p, b):
    q = abs(p) - b
    outside = length(max(q, 0.0))
    inside  = min(max(q.x, q.y), 0.0)
    return outside + inside
```

Os dois casos importam: fora da caixa `max(q, 0)` mede a distância reta até o canto/aresta; dentro, `min(max(q.x, q.y), 0)` dá o valor negativo até a parede mais próxima.

[Abrir a cena 05_sdf_ops](scene:05_sdf_ops): troque a chamada de `sdBox` por `sdCircle` no mesmo ponto e confirme que a estrutura `d < 0 ? dentro : fora` não muda.

## 3. min e max são união e interseção

Combinar formas é combinar campos, não pixels. O mínimo de dois SDFs é a união (mais perto de qualquer superfície); o máximo é a interseção (dentro de ambas). Subtração: `max(a, -b)`.

```
uniao    = min(d1, d2)
inter    = max(d1, d2)
diferenca = max(d1, -d2)
```

Na cena 05 os dois objetos orbitam e se combinam exatamente com essas três linhas. Repare que `max` e `min` deformam o campo: perto do encontro de duas formas, a "distância verdadeira" deixa de ser exata, e é por isso que existem os smooth minimum (assunto para quando você escrever o seu `sdf.slang` — dentro de `namespace Sdf`, chamável como `Sdf::esfera(...)`).

[Abrir a cena 05_sdf_ops](scene:05_sdf_ops): troque `min` por `max` no lugar indicado e identifique o que acontece com a interseção; depois troque `max(d1, d2)` por `max(d1, -d2)`.

## 4. Da distância à máscara

O campo vira imagem com um remap suave: `smoothstep(-w, w, d)` vale 0 dentro, 1 fora, transicionando numa faixa de largura `2w` centrada na borda — o `w` é a sua espessura de anti-aliasing, em unidades de cena.

```
mask = 1.0 - smoothstep(-w, w, d)   // 1 dentro, 0 fora
borda = smoothstep(-w, w, abs(d))   // só a linha da borda
```

Escolher `w` relativo à resolução (`w = 1.5 / iResolution.y`) mantém a borda com espessura constante em pixels.

[Abrir a cena 04_shapes](scene:04_shapes): troque o `softness` fixo por `1.5 / Uniforms.iResolution.y` e redimensione a janela — a borda não engrossa.

## Próximo passo

Campos de distância em 2D são o vocabulário; o próximo passo é percorrê-los em 3D com um raio. Siga a trilha [Caminhar até a superfície](trail:raymarching).
