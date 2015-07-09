require_dependency 'spree/calculator'
module Spree
  class Calculator::Avatax < Spree::Calculator
    def self.description
      I18n.t(:avalara_tax)
    end

    def compute(computable)
      case computable
      when Spree::LineItem
        compute_line_item(computable)
      when Spree::Shipment
        # TODO: this should be configurable based on tax_category
        0
      else
        raise "Unsupported tax computation for #{computable.class}"
      end
    end

    def compute_shipping_rate(shipping_rate)
      0
    end

    private

    def rate
      self.calculable
    end

    def compute_line_item(line_item)
      return 0 unless (line_item.product.tax_category == rate.tax_category) && line_item.order.ship_address.present?
      line_amount = line_item.price * line_item.quantity
      order       = line_item.order
      tax_rate    = order.respond_to?(:tax_rate) ? order.tax_rate : nil

      return BigDecimal.new(line_amount * tax_rate) if tax_rate

      credits = line_item.adjustments.select{|a| a.amount < 0}
      discount = - credits.sum(&:amount)

      Avalara.password = AvataxConfig.password
      Avalara.username = AvataxConfig.username
      Avalara.endpoint = AvataxConfig.endpoint

      invoice_line = Avalara::Request::Line.new(
        line_no: 1,
        destination_code: '1',
        origin_code: '1',
        qty: line_item.quantity.to_s,
        amount: line_amount.to_s,
        discounted: true
      )

      address = order.ship_address
      invoice_address = Avalara::Request::Address.new(
        address_code: '1',
        line_1: address.address1.to_s,
        line_2: address.address2.to_s,
        city: address.city.to_s,
        postal_code: address.zipcode.to_s
      )

      invoice = Avalara::Request::Invoice.new(
        customer_code: order.email,
        doc_date: Date.today,
        doc_type: 'SalesOrder',
        company_code: AvataxConfig.company_code,
        doc_code: "#{order.number}-#{order.line_items.index(line_item)}",
        discount: discount.to_s
      )

      invoice.addresses = [invoice_address]
      invoice.lines = [invoice_line]

      #Log request
      logger.debug invoice.to_s

      invoice_tax = Avalara.get_tax(invoice)

      if order.respond_to?(:tax_rate)
        tot_tax = invoice_tax.total_tax.to_f / line_amount
        tot_tax = 0 if tot_tax.is_a?(Float) && tot_tax.nan?
        begin
          order.update_column(:tax_rate, BigDecimal(tot_tax, 2))
        rescue Exception => e
          logger.fatal(e)
        end
      end

      #Log Response
      logger.debug invoice_tax.to_s
      BigDecimal.new(invoice_tax.total_tax)
    end

 end
end
