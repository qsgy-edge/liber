# 繁体→简体 accuracy, measured against references

A disagreement is not proof of an error: the reference is one community's
choice (Wikipedia's `zh-cn` variant renderer, OpenCC's hand-made cases), and
Chinese word choice for Taiwan→mainland conversion has no legal standard.
The per-candidate pairs below are what to read first; `eval-report.json` keeps
full sample rows, and the short-row columns restrict the judgement to rows of
32 code units or fewer, where the character alignment is trustworthy.

## opencc (174 rows)

| candidate | exact | error positions | error rate | short exact | short error rate | missed | wrong | over | candidate keeps Traditional | reference keeps Traditional | wording differs | unchanged kept |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| frozen | 83/174 (47.7%) | 619 | 14.42% | 71/140 (50.7%) | 13.59% | 316 | 181 | 122 | 2 | 25 | 154 | 6/8 |
| liber-now | 71/174 (40.8%) | 633 | 14.74% | 58/140 (41.4%) | 15.89% | 338 | 180 | 115 | 1 | 30 | 149 | 8/8 |
| hanlp | 74/174 (42.5%) | 629 | 14.64% | 58/140 (41.4%) | 15.88% | 332 | 182 | 115 | 1 | 30 | 151 | 8/8 |
| hanlp+exclude | 71/174 (40.8%) | 633 | 14.74% | 58/140 (41.4%) | 15.89% | 338 | 180 | 115 | 1 | 30 | 149 | 8/8 |
| hanlp+tw+hk | 82/174 (47.1%) | 362 | 8.62% | 67/140 (47.9%) | 11.82% | 59 | 86 | 217 | 14 | 5 | 67 | 6/8 |
| opencc-t2s | 67/174 (38.5%) | 655 | 15.25% | 55/140 (39.3%) | 16.21% | 362 | 181 | 112 | 1 | 30 | 150 | 8/8 |
| opencc-t2s+exclude | 64/174 (36.8%) | 659 | 15.35% | 55/140 (39.3%) | 16.23% | 368 | 179 | 112 | 1 | 30 | 148 | 8/8 |
| opencc-tw2s | 69/174 (39.7%) | 693 | 16.14% | 57/140 (40.7%) | 17.20% | 357 | 181 | 155 | 1 | 30 | 150 | 8/8 |
| opencc-tw2sp | 66/174 (37.9%) | 643 | 15.00% | 53/140 (37.9%) | 16.77% | 281 | 174 | 188 | 6 | 26 | 142 | 6/8 |

- **frozen** most frequent disagreements (reference→candidate): 互联网→因特网×9, 装内存条→装内存×8, 罗来纳→罗莱纳×6, 异→猴×4, →序设计×3, 梿→莲×3, 机→概×3, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 宏调用→宏×2
  - left as-is where the reference converted: 干×70, 氨×19, 溪×12, 希尔哈撒韦×8, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, ×5, 沉×5, 丁×5, 细胞与红细胞计数×4
  - converted where the reference did not: 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 借×8, 修×8, ×7, 泛×6, 宁×6, 厘×5, 猕×4
- **liber-now** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 氨×21, 宏×12, 溪×12, 干×10, 希尔哈撒韦×8, ×7, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5, 丁×5
  - converted where the reference did not: 干×20, 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 修×8, 泛×6, 宁×6, 厘×5, 借×4, 序×3
- **hanlp** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 氨×21, 宏×12, 溪×12, 干×10, 希尔哈撒韦×8, ×7, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5, 丁×5
  - converted where the reference did not: 干×20, 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 修×8, 泛×6, 宁×6, 厘×5, 借×4, 序×3
- **hanlp+exclude** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 氨×21, 宏×12, 溪×12, 干×10, 希尔哈撒韦×8, ×7, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5, 丁×5
  - converted where the reference did not: 干×20, 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 修×8, 泛×6, 宁×6, 厘×5, 借×4, 序×3
- **hanlp+tw+hk** most frequent disagreements (reference→candidate): 机→×7, 几→×5, 会→×4, 辉→英伟达×3, 达→英伟达×3, 梿→莲×3, 摄→前×2, 护→列×2, 忧→抑×2, 脏→腺×2, 灵→林×2, 断→滞剂后×2
  - left as-is where the reference converted: 溪×12, 干×10, 沉×5, 札×5, 着×4, 凤×4, 狸×4, 坯×4, 决异×2, 捍×2, 夹×2, 硅×1
  - converted where the reference did not: ×22, 氨×21, 干×20, 升×18, 复选×12, 伙×12, 搜×11, 苏×10, 秘×9, 细胞与红细胞计数×8, 修×8, 谢综合征×6
- **opencc-t2s** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 抬×28, 氨×21, 宏×12, 溪×12, 干×10, ×8, 希尔哈撒韦×8, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5
  - converted where the reference did not: 干×20, 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 修×8, 泛×6, 宁×6, 厘×5, 借×4, 克×3
- **opencc-t2s+exclude** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 抬×28, 氨×21, 宏×12, 溪×12, 干×10, ×8, 希尔哈撒韦×8, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5
  - converted where the reference did not: 干×20, 升×18, 伙×12, 搜×11, 苏×10, 秘×9, 修×8, 泛×6, 宁×6, 厘×5, 借×4, 克×3
- **opencc-tw2s** most frequent disagreements (reference→candidate): 互联网→网×4, 互联网→际×2, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 罗来纳→罗×2, 罗来纳→莱×2, 罗来纳→纳×2, 弗吉→维×2, 谷→麸×2, 几→机×2
  - left as-is where the reference converted: 抬×28, 氨×21, 宏×12, 溪×12, 干×10, ×8, 希尔哈撒韦×8, 大众×6, 复选×6, 斯科塞×6, 斯皮尔伯格×6, 沉×5
  - converted where the reference did not: 擡×28, 干×20, 升×18, 伙×12, 搜×11, 苏×10, 幺×9, 秘×9, 借×8, 修×8, 泛×6, 宁×6
- **opencc-tw2sp** most frequent disagreements (reference→candidate): 装内存条→装内存×8, 辉→英伟达×3, 达→英伟达×3, 机→几×3, 特→乌×2, 宝洁→宝×2, 宝洁→侨×2, 欧莱→莱×2, 摄→前×2, 护→列×2, 忧→抑×2, 脏→腺×2
  - left as-is where the reference converted: 抬×28, 氨×20, 溪×12, 干×10, 希尔哈撒韦×8, 大众×6, 斯科塞×6, 斯皮尔伯格×6, ×5, 沉×5, 丁×5, 札×5
  - converted where the reference did not: 擡×28, 干×20, 升×18, 复选×12, 伙×12, 搜×11, 苏×10, 幺×9, 秘×9, 借×8, 修×8, 泛×6

## wikipedia (18658 rows)

| candidate | exact | error positions | error rate | short exact | short error rate | missed | wrong | over | candidate keeps Traditional | reference keeps Traditional | wording differs | unchanged kept |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| frozen | 12271/18658 (65.8%) | 38145 | 3.97% | 6641/7540 (88.1%) | 2.65% | 3239 | 14402 | 20504 | 2862 | 1474 | 10066 | 745/990 |
| liber-now | 12839/18658 (68.8%) | 35720 | 3.72% | 6594/7540 (87.5%) | 2.73% | 4530 | 11834 | 19356 | 59 | 1919 | 9856 | 745/990 |
| hanlp | 12955/18658 (69.4%) | 35558 | 3.71% | 6631/7540 (87.9%) | 2.69% | 4272 | 11866 | 19420 | 59 | 1925 | 9882 | 743/990 |
| hanlp+exclude | 12839/18658 (68.8%) | 35720 | 3.72% | 6594/7540 (87.5%) | 2.73% | 4530 | 11834 | 19356 | 59 | 1919 | 9856 | 745/990 |
| hanlp+tw+hk | 12095/18658 (64.8%) | 37810 | 3.93% | 6642/7540 (88.1%) | 2.54% | 3003 | 13894 | 20913 | 2989 | 1184 | 9721 | 743/990 |
| opencc-t2s | 11516/18658 (61.7%) | 40215 | 4.19% | 6312/7540 (83.7%) | 3.34% | 9593 | 11749 | 18873 | 59 | 1904 | 9786 | 744/990 |
| opencc-t2s+exclude | 11428/18658 (61.2%) | 40377 | 4.21% | 6279/7540 (83.3%) | 3.38% | 9851 | 11717 | 18809 | 59 | 1898 | 9760 | 746/990 |
| opencc-tw2s | 11592/18658 (62.1%) | 40129 | 4.19% | 6301/7540 (83.6%) | 3.35% | 9367 | 11760 | 19002 | 59 | 1904 | 9797 | 741/990 |
| opencc-tw2sp | 10920/18658 (58.5%) | 42123 | 4.38% | 6361/7540 (84.4%) | 3.16% | 7663 | 13789 | 20671 | 3008 | 1152 | 9629 | 740/990 |

- **frozen** most frequent disagreements (reference→candidate): 档→盘×2539, 互联网档→因特网文件馆×2040, 档备→盘备×748, 馆→因特网文件馆×409, 互联网→因特网×172, 路→线×171, 站楼→厦×82, 台湾→台×53, 台湾→湾×53, 资→信×42, 讯→息×42, 车→士×39
  - left as-is where the reference converted: 米×373, 着×207, 伦×187, 线×172, ×135, 通×95, 万维网×68, 纳×45, 《×45, 能×42, 台式机×42, 》×42
  - converted where the reference did not: 运×703, 线×475, 湾×412, 因特网文件馆×409, 台×351, 铁×343, 车×305, 国×280, ”×273, “×269, 会×231, 统×231
- **liber-now** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: 互联网档×409, 米×373, 着×211, 伦×187, 线×173, ×141, 通×95, 络×90, 芯×90, 万维网×68, 能×53, 盘×48
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, ”×273, “×272, 会×231, 资×228, 计×227
- **hanlp** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: 互联网档×409, 米×373, 着×211, 线×172, ×141, 通×95, 络×90, 芯×90, 万维网×68, 能×53, 盘×48, 纳×45
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, ”×273, “×272, 会×231, 资×228, 计×227
- **hanlp+exclude** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: 互联网档×409, 米×373, 着×211, 伦×187, 线×173, ×141, 通×95, 络×90, 芯×90, 万维网×68, 能×53, 盘×48
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, ”×273, “×272, 会×231, 资×228, 计×227
- **hanlp+tw+hk** most frequent disagreements (reference→candidate): 档→盘×2538, 互联网档→互联网文件馆×2045, 档备→盘备×750, 馆→互联网文件馆×410, 路→线×170, 讯→信×91, 站楼→厦×83, 资→数×64, 启→激×61, 执→运×49, 资→信×43, 讯→息×43
  - left as-is where the reference converted: 米×375, 着×211, 伦×187, 线×173, ×119, 通×95, ‘×45, 《×45, ’×44, 》×42, 城×42, 分×40
  - converted where the reference did not: 运×701, 线×477, 湾×410, 互联网文件馆×410, 台×347, 铁×343, 车×324, 国×280, ”×272, “×268, 会×229, 区×226
- **opencc-t2s** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: “×2616, ”×2575, 互联网档×409, 米×373, 着×211, 线×172, ×142, 通×95, 络×90, 芯×90, 万维网×68, 能×53
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, 会×231, 资×228, 计×227, 统×221, 机×216
- **opencc-t2s+exclude** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: “×2616, ”×2575, 互联网档×409, 米×373, 着×211, 伦×187, 线×173, ×142, 通×95, 络×90, 芯×90, 万维网×68
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, 会×231, 资×228, 计×227, 统×221, 机×216
- **opencc-tw2s** most frequent disagreements (reference→candidate): 互联网档→网×818, 互联网档→际×409, 互联网档→档×409, 档备→档×375, 档备→备×375, 路→线×171, 台湾→台×88, 台湾→湾×88, 互联网→网×86, 站楼→厦×82, 件→体×60, 互联网→际×43
  - left as-is where the reference converted: “×2616, ”×2575, 互联网档×409, 米×373, 线×172, ×142, 通×95, 络×90, 芯×90, 万维网×68, 能×53, 盘×48
  - converted where the reference did not: 运×704, 线×439, 湾×415, 台×354, 铁×345, 车×325, 国×281, 会×231, 资×228, 计×227, 统×221, 机×216
- **opencc-tw2sp** most frequent disagreements (reference→candidate): 档→盘×2538, 互联网档→互联网文件馆×2045, 档备→盘备×750, 馆→互联网文件馆×410, 路→线×170, 讯→信×91, 站楼→厦×83, 资→数×64, 启→激×61, 执→运×49, 资→信×43, 讯→息×43
  - left as-is where the reference converted: “×2615, ”×2574, 米×375, 线×172, ×119, ‘×45, 《×45, ’×44, 》×42, 城×42, 分×40, 份×40
  - converted where the reference did not: 运×701, 线×477, 湾×411, 互联网文件馆×410, 台×347, 铁×343, 车×324, 国×280, 会×229, 区×226, 计×223, 统×217

