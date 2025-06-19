# 仕様

## 要件概要

- terraform の plan 結果を分析する script
- 簡易的な表示と詳細の表示を行う
- markdown 形式の出力に対応する


## 詳細設計


### plan 結果を json 形式の format に変換する
terraform plan -out=planfile と terraform show -json tfplan > tfplan.json を利用して plan 結果を json 形式に出力する

### jq を利用した解析

resource と output の変更を解析する


### resource の変更の解析方法

`resource_changes`の配列の中で `change.actions` の要素から判別を行う

以下の種類に分類を行う

- create
  - `change.actions` の要素が `create` のみの場合
- update
  - `change.actions` の要素が `update` のみの場合
- update (import)
  - `change.actions` の要素が `update` のみの場合、かつ `change.importing`の要素がある場合
- delete
  - `change.actions` の要素が `delete` のみの場合
- replace 
  - `change.actions` の要素が `create`と`delete`の二つの要素があり、`action_reason`に`replace_because_canet_update` となっている場合
- replace (import)
  - `change.actions` の要素が `create`と`delete`の二つの要素があり、また `action_reason`に`replace_because_canet_update` となっていて、更に `change.importing` の要素がある場合
- import (nochange)
  - `change.actions` が `no-op` の要素のみ、かつ`change.importing`の要素がある場合
- remove (forget)
  - `change.actions` の要素が `forget`のみの場合




### output の変更の解析方法
`output_changes` の 各要素の中の `actions` の中から判別可能

output の変更
- create
  - `actions`が `create` のみの場合
- update
  - `actions`が `update` のみの場合
- delete 
  - `actions`が `delete` のみの場合