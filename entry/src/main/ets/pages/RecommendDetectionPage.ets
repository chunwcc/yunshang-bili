/**
 * 推荐检测页面
 * 用于验证推荐功能是否正常工作
 */
import { RecommendDetector, DetectionResult } from '../utils/RecommendDetector';

@Entry
@Component
struct RecommendDetectionPage {
  @State detectionResult: DetectionResult | null = null;
  @State isDetecting: boolean = false;
  @State reportText: string = '';
  @State testHistory: string[] = [];
  
  build() {
    Column() {
      // 标题栏
      Row() {
        Text('推荐功能检测')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
        
        Blank()
        
        Button('返回')
          .onClick(() => {
            // router.back();
          })
      }
      .width('100%')
      .padding(16)
      
      Scroll() {
        Column() {
          // 检测按钮
          this.DetectionButtons()
          
          // 检测结果
          if (this.detectionResult) {
            this.DetectionResultView()
          }
          
          // 检测报告
          if (this.reportText) {
            this.ReportView()
          }
          
          // 测试历史
          if (this.testHistory.length > 0) {
            this.TestHistoryView()
          }
        }
        .padding(16)
      }
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
    }
    .backgroundColor('#F5F5F5')
  }
  
  @Builder
  DetectionButtons() {
    Column() {
      Text('检测工具')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 16 })
      
      Row() {
        Button('完整检测')
          .width('45%')
          .enabled(!this.isDetecting)
          .onClick(() => this.runFullDetection())
        
        Blank()
        
        Button('对比测试')
          .width('45%')
          .enabled(!this.isDetecting)
          .onClick(() => this.runCompareTest())
      }
      .width('100%')
      .margin({ bottom: 12 })
      
      Row() {
        Button('快速检测')
          .width('45%')
          .enabled(!this.isDetecting)
          .onClick(() => this.runQuickDetection())
        
        Blank()
        
        Button('生成报告')
          .width('45%')
          .enabled(this.detectionResult !== null)
          .onClick(() => this.generateReport())
      }
      .width('100%')
    }
    .backgroundColor(Color.White)
    .borderRadius(12)
    .padding(16)
    .margin({ bottom: 16 })
  }
  
  @Builder
  DetectionResultView() {
    Column() {
      Row() {
        Text('检测结果')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        
        Blank()
        
        Text(`${this.detectionResult?.score}/100`)
          .fontSize(16)
          .fontColor(this.getScoreColor(this.detectionResult?.score || 0))
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .margin({ bottom: 16 })
      
      // 状态指示器
      this.StatusIndicator()
      
      // 详细信息
      this.DetailInfo()
    }
    .backgroundColor(Color.White)
    .borderRadius(12)
    .padding(16)
    .margin({ bottom: 16 })
  }
  
  @Builder
  StatusIndicator() {
    Column() {
      // Cookie状态
      this.StatusItem(
        'Cookie状态',
        this.detectionResult?.details.cookieStatus.isValid || false,
        this.getCookieStatusText()
      )
      
      Divider().margin({ top: 8, bottom: 8 })
      
      // 参数状态
      this.StatusItem(
        '推荐参数',
        this.detectionResult?.details.paramStatus.isValid || false,
        this.getParamStatusText()
      )
      
      Divider().margin({ top: 8, bottom: 8 })
      
      // 推荐状态
      this.StatusItem(
        '推荐功能',
        this.detectionResult?.details.recommendStatus.canFetchRecommend || false,
        this.getRecommendStatusText()
      )
      
      Divider().margin({ top: 8, bottom: 8 })
      
      // 行为状态
      this.StatusItem(
        '行为数据',
        this.detectionResult?.details.behaviorStatus.hasWatchedVideos || false,
        this.getBehaviorStatusText()
      )
    }
  }
  
  @Builder
  StatusItem(title: string, isSuccess: boolean, detail: string) {
    Row() {
      Text(title)
        .fontSize(14)
        .layoutWeight(1)
      
      Text(detail)
        .fontSize(12)
        .fontColor('#666666')
        .margin({ right: 8 })
      
      Text(isSuccess ? '✅' : '❌')
        .fontSize(16)
    }
    .width('100%')
  }
  
  @Builder
  DetailInfo() {
    Column() {
      // 问题列表
      if (this.detectionResult && this.detectionResult.issues.length > 0) {
        Text('问题列表')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 16, bottom: 8 })
        
        ForEach(this.detectionResult.issues, (issue: string) => {
          Row() {
            Text('❌')
              .fontSize(14)
            Text(issue)
              .fontSize(13)
              .margin({ left: 8 })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 4 })
        })
      }
      
      // 建议列表
      if (this.detectionResult && this.detectionResult.suggestions.length > 0) {
        Text('优化建议')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 16, bottom: 8 })
        
        ForEach(this.detectionResult.suggestions, (suggestion: string) => {
          Row() {
            Text('💡')
              .fontSize(14)
            Text(suggestion)
              .fontSize(13)
              .margin({ left: 8 })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 4 })
        })
      }
    }
    .width('100%')
  }
  
  @Builder
  ReportView() {
    Column() {
      Row() {
        Text('检测报告')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        
        Blank()
        
        Button('复制')
          .fontSize(12)
          .height(32)
          .onClick(() => {
            // 复制到剪贴板
            this.getUIContext().getPromptAction().showToast({ message: '报告已复制' });
          })
      }
      .width('100%')
      .margin({ bottom: 12 })
      
      Text(this.reportText)
        .fontSize(12)
        .fontFamily('monospace')
        .width('100%')
    }
    .backgroundColor(Color.White)
    .borderRadius(12)
    .padding(16)
    .margin({ bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }
  
  @Builder
  TestHistoryView() {
    Column() {
      Text('测试历史')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 12 })
      
      ForEach(this.testHistory, (record: string, index: number) => {
        Text(record)
          .fontSize(12)
          .width('100%')
          .margin({ bottom: 4 })
      })
    }
    .backgroundColor(Color.White)
    .borderRadius(12)
    .padding(16)
    .margin({ bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }
  
  // ========== 业务逻辑 ==========
  
  private async runFullDetection(): Promise<void> {
    this.isDetecting = true;
    this.addHistory('开始完整检测...');
    
    try {
      const result = await RecommendDetector.runFullDetection();
      this.detectionResult = result;
      
      this.addHistory(`检测完成，得分: ${result.score}/100`);
      
      if (result.success) {
        this.getUIContext().getPromptAction().showToast({ message: '检测通过！推荐功能正常' });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '检测未通过，请查看详情' });
      }
      
    } catch (err) {
      this.addHistory(`检测失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '检测失败' });
    } finally {
      this.isDetecting = false;
    }
  }
  
  private async runQuickDetection(): Promise<void> {
    this.isDetecting = true;
    this.addHistory('开始快速检测...');
    
    try {
      // 只检测Cookie和参数
      const result = await RecommendDetector.runFullDetection();
      this.detectionResult = result;
      
      this.addHistory(`快速检测完成`);
      this.getUIContext().getPromptAction().showToast({ message: '快速检测完成' });
      
    } catch (err) {
      this.addHistory(`快速检测失败: ${err}`);
    } finally {
      this.isDetecting = false;
    }
  }
  
  private async runCompareTest(): Promise<void> {
    this.isDetecting = true;
    this.addHistory('开始对比测试...');
    
    try {
      await RecommendDetector.compareTest();
      this.addHistory('对比测试完成');
      this.getUIContext().getPromptAction().showToast({ message: '对比测试完成，请查看日志' });
      
    } catch (err) {
      this.addHistory(`对比测试失败: ${err}`);
    } finally {
      this.isDetecting = false;
    }
  }
  
  private generateReport(): void {
    if (this.detectionResult) {
      this.reportText = RecommendDetector.generateReport(this.detectionResult);
      this.addHistory('生成检测报告');
      this.getUIContext().getPromptAction().showToast({ message: '报告已生成' });
    }
  }
  
  private addHistory(record: string): void {
    const timestamp = new Date().toLocaleTimeString();
    this.testHistory.push(`[${timestamp}] ${record}`);
    
    // 保留最近20条
    if (this.testHistory.length > 20) {
      this.testHistory = this.testHistory.slice(-20);
    }
  }
  
  // ========== 辅助方法 ==========
  
  private getScoreColor(score: number): string {
    if (score >= 80) return '#4CAF50';
    if (score >= 60) return '#FF9800';
    return '#F44336';
  }
  
  private getCookieStatusText(): string {
    if (!this.detectionResult) return '';
    const status = this.detectionResult.details.cookieStatus;
    return `用户: ${status.userMid !== '0' ? '已登录' : '未登录'}`;
  }
  
  private getParamStatusText(): string {
    if (!this.detectionResult) return '';
    const status = this.detectionResult.details.paramStatus;
    return `${status.paramCount}/4 参数`;
  }
  
  private getRecommendStatusText(): string {
    if (!this.detectionResult) return '';
    const status = this.detectionResult.details.recommendStatus;
    return `${status.recommendCount} 条推荐`;
  }
  
  private getBehaviorStatusText(): string {
    if (!this.detectionResult) return '';
    const status = this.detectionResult.details.behaviorStatus;
    return `${status.watchedCount} 条记录`;
  }
}
