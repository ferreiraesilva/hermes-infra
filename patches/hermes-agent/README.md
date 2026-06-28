# Hermes Agent runtime overlays

Patches deste diretório são reaplicados pelo `deploy-instance.sh` sobre arquivos
extraídos da imagem Hermes pinada. O container recebe os arquivos por bind mount;
nenhuma edição manual é feita dentro dele.

## `video-caption.patch`

Adiciona `MEDIA_CAPTION` exclusivamente para arquivos de vídeo. O fluxo existente
de imagens (`![legenda](url)`) não é interceptado nem alterado.

O deploy executa `git apply --check` e `py_compile` antes de reiniciar o gateway.
Se uma atualização da imagem tornar o patch incompatível, o deploy para e exige
que o patch seja refeito sobre o novo `main` do Hermes Agent.
