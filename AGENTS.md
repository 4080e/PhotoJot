# PhotoJot

## コンセプト
自宅ストレージの写真・動画を、フォルダを意識せず、撮影した日付順に見る。

## v1 基本方針
- iPhone / iPad対応。iOS 18.6以上。
- Apple標準UI・標準フレームワークを優先する。
- SMB上の原本は読み取り専用。削除・移動・編集・アップロードしない。
- File Providerではなく、SMBClientによる直接SMBアクセスを使用する。
- SMBClientはv1で0.3.1を使用する。
- metadata indexにはSwiftDataを使用する。
- SMBパスワードはKeychainに保存し、SwiftDataやUserDefaultsには保存しない。
- v1の主要メディア形式はJPEG/JPG、HEIC、MOV、MP4。PNGは主要表示対象にしない。
- thumbnailは再生成可能なcacheとしてLibrary/Cachesに保存する。
- 写真全画面表示は、SMBから一時ファイルへ取得し、ImageIOで表示サイズへdownsampleする。
- 動画thumbnail・動画再生はAVAssetResourceLoader + SMB range readを基本方式とする。
- 動画全体を一時ファイルへ取得する方式は基本経路にしない。

## 開発方針
- PhotoJotPoCで成立済みの方式を、明確な理由なく置き換えたり再PoCしたりしない。
- 調査で判断できる事項は、追加PoCより先に仕様・API・利用ライブラリを調査する。
- 過剰設計を避け、v1に必要な最小構成から実装する。
- thumbnail prefetch、動画range cache、複数SMB接続による並列化、高度なbackground処理は初期v1の必須機能にしない。
